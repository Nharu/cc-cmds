#!/usr/bin/env python3
"""Find open tracker items similar to one issue or to a draft.

    similar-items.py github  [--repo OWNER/NAME] (--issue N | --title T --body-file F) [common]
    similar-items.py clickup (--task ID|URL | --list ID --title T --body-file F) [common]
    similar-items.py clickup --lexical-only --list-fields LIST [--task-fields ID ...] --log FILE
    similar-items.py file    --corpus FILE.json   (--issue N | --title T --body-file F) [common]
    common: [--format text|json] [--lexical-only] [--replay-log FILE [--replay-tag-prefix P]]
            [--question measured|generic] [--log PATH] [--patient]

Every open item is scored against the query by lexical overlap, the top 20
are judged pair by pair by a type-decision classification model, and the top
3 of the re-ranked list are printed with their probability. The JSON output
also carries `same_title`: every fetched open item whose normalized title
(NFC, whitespace folded, ends stripped) equals the query's, counted over the
whole fetched corpus rather than the shortlist. It only PRESENTS
candidates: nothing here writes to a tracker, and nothing blocks or delays the
registration or the start of work that called it.

Exit codes: 0 for every lookup outcome (semantic, partial, lexical,
unavailable), 2 for a usage error, 1 for an internal error. A lookup that could
not run is `status=unavailable` with exit 0, so the caller carries on.

Field mode (`clickup --list-fields`) is not a similarity lookup. It reads every
page of one list's open tickets, subtasks included, and each `--task-fields`
ticket one by one, and writes a field document to the `--log` path: here
`--log` is the path of that document, not a judgment log. The document's first
key is `"kind": "fields"`; a read stopped by the 2000-ticket limit, the 60 s
budget, a failed page or a failed ticket read, or one that could not start,
carries `"partial": true` and the reason. It runs no judgment step and calls no
model. Stdout carries one summary line; the exit code is 0 for a full and a
partial document alike, so the caller decides by reading `partial`.

Run it by path, with no interpreter in front: the gate grades the basename,
and an interpreter prefix is graded as an opaque worktree write.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import cc_tracker  # noqa: E402

GH_LIMIT = 3000
GH_TIMEOUT = 60
GH_FIELDS = "number,title,body,url"

# The wording a judgment request carries, by adapter. ClickUp has no labelled
# pairs to measure either wording on, and the measured wording describes a
# repository, which a ClickUp space is not.
DEFAULT_QUESTION = {"github": "measured", "file": "measured", "clickup": "generic"}

SAME_LIST = "같은 리스트"

LEXICAL = "의미 판정 없이 어휘 겹침만으로 고른 후보다"
NOTICE = {
    "key-absent": LEXICAL + " (사유: 판정 키 없음).",
    "key-invalid": LEXICAL + " (사유: 판정 키 파일을 쓸 수 없음 — 모드 600 인 일반 파일이어야 함).",
    "requested": LEXICAL + " (사유: 요청에 따른 어휘 전용 실행).",
    "timeout": LEXICAL + " (사유: 판정 시간 초과).",
    "no-response": LEXICAL + " (사유: 판정 응답 없음).",
    "no-candidates": "대조할 열린 항목이 없다.",
    "query": "질의 이슈를 가져오지 못해 유사 이슈 조회를 하지 못했다 — 착수는 그대로 진행한다.",
    "corpus": "열린 이슈 목록을 가져오지 못해 유사 이슈 조회를 하지 못했다 — 등록·착수는 그대로 진행한다.",
    "no-overlap": "겹치는 열린 항목이 없다.",
    "tracker-key": "ClickUp 토큰이 ~/.config/cc-cmds/clickup.env 에 없어 유사 티켓 조회를 하지 못했다 — 진행은 막지 않는다.",
    "tracker-key-invalid": "ClickUp 토큰 파일을 쓸 수 없어 유사 티켓 조회를 하지 못했다 — "
                           "chmod 600 ~/.config/cc-cmds/clickup.env 가 필요하다. 진행은 막지 않는다.",
}


def notice_rejected(code):
    return LEXICAL + " (사유: 판정 요청 거부 HTTP %s)." % code


def notice_partial(k, missing):
    return "후보 %d건 중 %d건은 의미 판정을 받지 못해 어휘 순서로 뒤에 붙였다." % (k, missing)


def notice_mismatch(value):
    return "응답 모델이 고정 모델과 달랐다(%s) — 순위는 쓰되 측정 조건과 다르다." % value


def notice_truncated(limit):
    return "열린 항목이 %d건 이상이라 앞의 %d건만 대조했다." % (limit, limit)


class Unavailable(Exception):
    def __init__(self, reason, source):
        super().__init__(reason)
        self.reason = reason
        self.source = source


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

def build_parser():
    # Abbreviations are refused on every parser. The gate grades this tool by
    # the option spellings it can see, and an accepted `--lo` for `--log` would
    # be a file write the gate reads as a plain read.
    common = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    common.add_argument("--format", choices=("text", "json"), default="text")
    common.add_argument("--lexical-only", action="store_true")
    common.add_argument("--replay-log")
    common.add_argument("--replay-tag-prefix")
    common.add_argument("--question", choices=tuple(sorted(cc_tracker.QUESTIONS)))
    common.add_argument("--log")
    common.add_argument("--patient", action="store_true")
    query = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    query.add_argument("--issue")
    query.add_argument("--title")
    query.add_argument("--body-file")

    parser = argparse.ArgumentParser(prog="similar-items.py", allow_abbrev=False,
                                     description="Find open tracker items similar to an issue or a draft.")
    sub = parser.add_subparsers(dest="adapter", metavar="{github,clickup,file}")
    sub.required = True
    gh = sub.add_parser("github", parents=[query, common], allow_abbrev=False)
    gh.add_argument("--repo")
    cu = sub.add_parser("clickup", parents=[common], allow_abbrev=False)
    cu.add_argument("--task")
    cu.add_argument("--list")
    cu.add_argument("--title")
    cu.add_argument("--body-file")
    cu.add_argument("--list-fields", metavar="LIST",
                    help="field mode: write the list's ticket fields to the --log path")
    cu.add_argument("--task-fields", metavar="ID", action="append",
                    help="field mode: also read this ticket by itself (repeatable)")
    fl = sub.add_parser("file", parents=[query, common], allow_abbrev=False)
    fl.add_argument("--corpus", required=True)
    return parser, {"github": gh, "clickup": cu, "file": fl}


def check_args(args, subparsers):
    sp = subparsers[args.adapter]
    draft = args.title is not None or args.body_file is not None
    if args.adapter == "clickup" and (args.list_fields is not None or args.task_fields):
        if args.list_fields is None:
            sp.error("--task-fields needs --list-fields")
        if not args.lexical_only or args.log is None:
            sp.error("--list-fields needs --lexical-only and --log FILE")
        if (args.task is not None or args.list is not None or draft or args.replay_log is not None
                or args.replay_tag_prefix is not None or args.question is not None):
            sp.error("--list-fields cannot be combined with --task/--list/--title/--body-file/"
                     "--replay-log/--question")
        return
    if args.adapter == "clickup":
        if args.task is not None and (draft or args.list is not None):
            sp.error("--task cannot be combined with --list/--title/--body-file")
        if args.task is None and not (args.list is not None and args.title is not None
                                      and args.body_file is not None):
            sp.error("give --task ID|URL, or all of --list, --title and --body-file")
    else:
        if args.issue is not None and draft:
            sp.error("--issue cannot be combined with --title/--body-file")
        if args.issue is None and not (args.title is not None and args.body_file is not None):
            sp.error("give --issue N, or both --title and --body-file")
    if args.adapter == "github" and args.issue is not None and not args.issue.isdigit():
        sp.error("--issue takes an issue number")
    if args.replay_tag_prefix is not None and args.replay_log is None:
        sp.error("--replay-tag-prefix needs --replay-log")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise cc_tracker.UsageError("cannot read %s (%s)" % (path, type(e).__name__))


# ---------------------------------------------------------------------------
# Corpus adapters
# ---------------------------------------------------------------------------

def gh_json(argv):
    """Run `gh` and decode its JSON, or None on any failure."""
    try:
        cp = subprocess.run(["gh"] + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=GH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if cp.returncode != 0:
        return None
    try:
        return json.loads(cp.stdout.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


def as_item(x, id_key="number"):
    ident = x.get(id_key)
    if ident is None:
        ident = x.get("id")
    return {"id": ident, "title": x.get("title") or "", "body": x.get("body") or "", "url": x.get("url") or ""}


def repo_of(items):
    for item in items:
        m = re.search(r"github\.com/([^/]+/[^/]+)/", item.get("url") or "")
        if m:
            return m.group(1)
    return None


def github_corpus(args):
    repo_args = ["--repo", args.repo] if args.repo else []
    source = "github:" + (args.repo or "-")
    data = gh_json(["issue", "list", "--state", "open", "--limit", str(GH_LIMIT), "--json", GH_FIELDS] + repo_args)
    if not isinstance(data, list):
        raise Unavailable("corpus", source)
    corpus = [as_item(x) for x in data if isinstance(x, dict)]
    if not args.repo:
        source = "github:" + (repo_of(corpus) or "-")
    query = None
    if args.issue is not None:
        n = int(args.issue)
        query = next((item for item in corpus if item["id"] == n), None)
        if query is None:
            # Started from a closed issue, or one the limit cut off.
            one = gh_json(["issue", "view", str(n), "--json", GH_FIELDS] + repo_args)
            if not isinstance(one, dict):
                raise Unavailable("query", source)
            query = as_item(one)
    return source, corpus, len(data) >= GH_LIMIT, GH_LIMIT, query


def file_corpus(args):
    source = "file:" + os.path.basename(args.corpus)
    try:
        with open(args.corpus, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        raise Unavailable("corpus", source)
    if not isinstance(data, list):
        raise Unavailable("corpus", source)
    corpus = [as_item(x) for x in data if isinstance(x, dict)]
    query = None
    if args.issue is not None:
        query = next((item for item in corpus if str(item["id"]) == args.issue), None)
        if query is None:
            raise Unavailable("query", source)
    return source, corpus, False, None, query


def task_id_of(value):
    """A ticket id, or the id taken from a ticket URL.

    A URL's id is the last non-empty path segment after `/t/`, which also
    covers the `/t/<team>/<custom id>` form. Anything else is the id as given.
    """
    path = urllib.parse.urlsplit(value).path if "://" in value else value
    if "/t/" in path:
        parts = [p for p in path.split("/t/", 1)[1].split("/") if p]
        if parts:
            return parts[-1]
    return value


def ref_of(obj, key):
    """The `id` of a nested ClickUp reference such as `list` or `space`."""
    ref = obj.get(key) if isinstance(obj, dict) else None
    ident = ref.get("id") if isinstance(ref, dict) else None
    return None if ident is None else str(ident)


def as_ticket(x):
    body = x.get("text_content") or x.get("description") or ""
    return {"id": str(x.get("id")), "title": x.get("name") or "", "body": body, "url": x.get("url") or "",
            "list_id": ref_of(x, "list")}


class ClickUp:
    """The ClickUp reads of one lookup, under one 60 s budget.

    Each request is capped at 15 s and at what is left of the budget; a
    budget that runs out is a failure like any other read.
    """

    def __init__(self, token):
        self.token = token
        self.end = time.monotonic() + cc_tracker.CLICKUP_TOTAL_TIMEOUT

    def get(self, path):
        left = self.end - time.monotonic()
        if left <= 0:
            raise cc_tracker.TrackerError("timeout")
        data = cc_tracker.clickup_get(path, self.token, min(cc_tracker.CLICKUP_PAGE_TIMEOUT, left))
        if not isinstance(data, dict):
            raise cc_tracker.TrackerError("json")
        return data


def q(value):
    return urllib.parse.quote(str(value), safe="")


def clickup_team_of_space(cu, space):
    """The workspace holding the space, asked of every workspace the token sees.

    The token can see more than one workspace, so the first one is not taken
    on trust.
    """
    teams = cu.get("/team").get("teams")
    for team in teams if isinstance(teams, list) else []:
        tid = team.get("id") if isinstance(team, dict) else None
        if tid is None:
            continue
        spaces = cu.get("/team/%s/space" % q(tid)).get("spaces")
        if any(isinstance(s, dict) and str(s.get("id")) == space for s in spaces if isinstance(spaces, list)):
            return str(tid)
    return None


def clickup_corpus(args):
    """(source, corpus, truncated, limit, query, query list id) for a space.

    The corpus is every open ticket (subtasks included) in the space that holds
    the query's list, fetched page by page until `last_page` or an empty page.
    """
    source = "clickup:-"
    token, why = cc_tracker.read_clickup_token()
    if token is None:
        raise Unavailable(why, source)
    cu = ClickUp(token)
    del token
    query = None
    try:
        if args.task is not None:
            try:
                t = cu.get("/task/%s" % q(task_id_of(args.task)))
            except cc_tracker.TrackerError:
                raise Unavailable("query", source)
            if t.get("id") is None:
                raise Unavailable("query", source)
            query = as_ticket(t)
            list_id, space, team = query["list_id"], ref_of(t, "space"), t.get("team_id")
            team = None if team is None else str(team)
        else:
            list_id = args.list
            space = ref_of(cu.get("/list/%s" % q(list_id)), "space")
            team = None if space is None else clickup_team_of_space(cu, space)
        if space is None or team is None:
            raise Unavailable("corpus", source)
        source = "clickup:space/" + space
        corpus, page, truncated = [], 0, False
        while True:
            data = cu.get("/team/%s/task?space_ids[]=%s&page=%d&include_closed=false&subtasks=true"
                          % (q(team), q(space), page))
            tasks = data.get("tasks")
            if not isinstance(tasks, list):
                raise Unavailable("corpus", source)
            corpus.extend(as_ticket(x) for x in tasks if isinstance(x, dict))
            if len(corpus) >= cc_tracker.CLICKUP_LIMIT:
                corpus, truncated = corpus[:cc_tracker.CLICKUP_LIMIT], True
                break
            if not tasks or data.get("last_page"):
                break
            page += 1
    except cc_tracker.TrackerError:
        raise Unavailable("corpus", source)
    return source, corpus, truncated, cc_tracker.CLICKUP_LIMIT, query, list_id


# ---------------------------------------------------------------------------
# Field mode
# ---------------------------------------------------------------------------

def opt_str(value):
    return None if value is None or value == "" else str(value)


def priority_of(x):
    """The priority as an integer 1-4, or None.

    The response carries an object whose `id` is the number as a string; any
    other shape is taken as unset rather than guessed.
    """
    ref = x.get("priority")
    ident = ref.get("id") if isinstance(ref, dict) else None
    try:
        n = int(str(ident))
    except ValueError:
        return None
    return n if 1 <= n <= 4 else None


def assignees_of(x):
    out = []
    for a in x.get("assignees") or []:
        ident = a.get("id") if isinstance(a, dict) else None
        try:
            out.append(int(str(ident)))
        except ValueError:
            continue
    return out


def dependencies_of(x):
    """Each dependency as the `task_id`/`depends_on` pair the response gives."""
    out = []
    for d in x.get("dependencies") or []:
        if not isinstance(d, dict):
            continue
        t, p = opt_str(d.get("task_id")), opt_str(d.get("depends_on"))
        if t is not None and p is not None:
            out.append({"task_id": t, "depends_on": p})
    return out


def fields_of(x):
    """One ticket's fields as the field document carries them.

    Dates stay the millisecond strings the response gives. A `*_date_time`
    flag is copied only when the response has the key: the API documentation
    shows none, and a flag that is not there is not guessed.
    """
    rec = {"id": str(x.get("id")), "name": x.get("name") or "", "parent": opt_str(x.get("parent")),
           "list_id": ref_of(x, "list"), "assignees": assignees_of(x),
           "tags": [t.get("name") for t in x.get("tags") or [] if isinstance(t, dict) and t.get("name")],
           "priority": priority_of(x), "start_date": opt_str(x.get("start_date")),
           "due_date": opt_str(x.get("due_date"))}
    for key in ("start_date_time", "due_date_time"):
        if key in x:
            rec[key] = x[key]
    rec["dependencies"] = dependencies_of(x)
    return rec


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(d, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise cc_tracker.UsageError("cannot write %s (%s)" % (path, type(e).__name__))


def read_failure(err, otherwise):
    return "budget" if str(err) == "timeout" else otherwise


def list_fields(args):
    """The field document of one list, partial when a read stopped it."""
    doc = {"kind": "fields", "list": args.list_fields, "partial": False, "reason": None,
           "tasks": [], "task_fields": []}
    token, why = cc_tracker.read_clickup_token()
    if token is None:
        doc["partial"], doc["reason"] = True, why
        return doc
    cu = ClickUp(token)
    del token
    page = 0
    try:
        while True:
            data = cu.get("/list/%s/task?subtasks=true&include_closed=false&page=%d"
                          % (q(args.list_fields), page))
            tasks = data.get("tasks")
            if not isinstance(tasks, list):
                raise cc_tracker.TrackerError("json")
            doc["tasks"].extend(fields_of(x) for x in tasks if isinstance(x, dict))
            if len(doc["tasks"]) >= cc_tracker.CLICKUP_LIMIT:
                doc["tasks"] = doc["tasks"][:cc_tracker.CLICKUP_LIMIT]
                doc["partial"], doc["reason"] = True, "limit"
                return doc
            if not tasks or data.get("last_page"):
                break
            page += 1
    except cc_tracker.TrackerError as e:
        doc["partial"], doc["reason"] = True, read_failure(e, "page-failed")
        return doc
    for ident in args.task_fields or []:
        try:
            t = cu.get("/task/%s" % q(task_id_of(ident)))
        except cc_tracker.TrackerError as e:
            doc["partial"], doc["reason"] = True, read_failure(e, "task-failed")
            return doc
        if t.get("id") is None:
            doc["partial"], doc["reason"] = True, "task-failed"
            return doc
        doc["task_fields"].append(fields_of(t))
    return doc


def run_fields(args):
    cc_tracker.clickup_base()
    doc = list_fields(args)
    write_atomic(args.log, json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    return "similar-items: fields list=%s tasks=%d task_fields=%d partial=%s\n" % (
        one_line(args.list_fields), len(doc["tasks"]), len(doc["task_fields"]),
        "true" if doc["partial"] else "false")


# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

def failure_reason(results):
    """(reason, notice) for a judgment step that left fewer than m judged."""
    fails = [f for _, _, f in results if f is not None]
    for kind, code in fails:
        if kind == "reject":
            return "http:%s" % code, notice_rejected(code)
    if any(kind == "timeout" for kind, _ in fails):
        return "timeout", NOTICE["timeout"]
    if any(kind == "replay-miss" for kind, _ in fails):
        return "replay-miss", NOTICE["no-response"]
    for kind, code in fails:
        if kind == "http":
            return "http:%s" % code, NOTICE["no-response"]
    return "net", NOTICE["no-response"]


def lookup(args):
    question = args.question or DEFAULT_QUESTION[args.adapter]
    query_list = None
    if args.adapter == "github":
        source, corpus, truncated, limit, query = github_corpus(args)
    elif args.adapter == "clickup":
        source, corpus, truncated, limit, query, query_list = clickup_corpus(args)
    else:
        source, corpus, truncated, limit, query = file_corpus(args)
    if query is None:
        query = {"id": None, "title": args.title, "body": read_text(args.body_file), "url": ""}

    ranked, _overlaps, shared = cc_tracker.shortlist(query, corpus)
    same = []
    for item in cc_tracker.same_title(query, corpus):
        s = {"id": item["id"], "title": item["title"], "url": item["url"]}
        if args.adapter == "clickup":
            s["same_list"] = query_list is not None and item.get("list_id") == str(query_list)
        same.append(s)
    k = len(ranked)
    m = min(cc_tracker.SHOWN, k)
    reasons, notices = [], []
    results = [(None, None, None)] * k
    status = "lexical"

    if k == 0:
        reasons.append("no-candidates")
        notices.append(NOTICE["no-candidates"])
    elif args.lexical_only:
        reasons.append("requested")
        notices.append(NOTICE["requested"])
    else:
        log = cc_tracker.LogWriter(args.log)
        if args.replay_log is not None:
            try:
                recs = cc_tracker.load_replay(args.replay_log)
            except (OSError, ValueError) as e:
                raise cc_tracker.UsageError("cannot read replay log (%s)" % type(e).__name__)
            results = cc_tracker.judge_replay(query, ranked, question, recs, args.replay_tag_prefix or "", log)
        else:
            key, why = cc_tracker.read_judge_key()
            if key is None:
                reasons.append(why)
                notices.append(NOTICE[why])
            else:
                results = cc_tracker.judge_live(query, ranked, question, key,
                                                cc_tracker.Budget(args.patient), log)
                del key
        if not reasons:
            judged_now = sum(1 for p, _, _ in results if p is not None)
            if judged_now == k:
                status = "semantic"
            elif judged_now >= m:
                status = "partial"
                reasons.append("partial")
                notices.append(notice_partial(k, k - judged_now))
            else:
                reason, text = failure_reason(results)
                reasons.append(reason)
                notices.append(text)
            if status != "lexical":
                odd = sorted({str(mod) for p, mod, _ in results if p is not None and mod != cc_tracker.MODEL})
                if odd:
                    reasons.append("model-mismatch")
                    notices.append(notice_mismatch(", ".join(odd)))

    if truncated:
        notices.append(notice_truncated(limit))
    if k and not any(shared):
        notices.append(NOTICE["no-overlap"])

    judged = sum(1 for p, _, _ in results if p is not None)
    order = list(range(k))
    if status != "lexical":
        # Judged candidates first by probability (ties keep lexical order),
        # the unjudged ones after them in lexical order. The two are not mixed.
        head = sorted((i for i in order if results[i][0] is not None), key=lambda i: -results[i][0])
        order = head + [i for i in order if results[i][0] is None]
    candidates = []
    for rank, i in enumerate(order, 1):
        item = ranked[i]
        p = results[i][0] if status != "lexical" else None
        cand = {"rank": rank, "id": item["id"], "title": item["title"], "url": item["url"],
                "lexical": i + 1, "p": p}
        if args.adapter == "clickup":
            cand["same_list"] = query_list is not None and item.get("list_id") == str(query_list)
        candidates.append(cand)
    return {
        "status": status, "source": source, "corpus": len(corpus), "shortlist": k, "judged": judged,
        "model": cc_tracker.MODEL if status != "lexical" else "-",
        "reason": ",".join(reasons), "notice": " · ".join(notices), "candidates": candidates,
        "same_title": same,
    }


def unavailable(exc):
    return {"status": "unavailable", "source": exc.source, "corpus": 0, "shortlist": 0, "judged": 0,
            "model": "-", "reason": exc.reason, "notice": NOTICE[exc.reason], "candidates": [],
            "same_title": []}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def one_line(s):
    return re.sub(r"[\t\r\n]+", " ", str(s))


def render_text(res, adapter):
    lines = ["similar-items: status=%s source=%s corpus=%d shortlist=%d judged=%d model=%s" % (
        res["status"], res["source"], res["corpus"], res["shortlist"], res["judged"], res["model"])]
    if res["notice"]:
        lines.append("notice: " + res["notice"])
    for c in res["candidates"][:cc_tracker.SHOWN]:
        # A ClickUp ticket id is printed as it is, even when it is all digits.
        numeric = isinstance(c["id"], int) or str(c["id"]).isdigit()
        ident = "#%s" % c["id"] if adapter != "clickup" and numeric else str(c["id"])
        p = "-" if c["p"] is None else "%.2f" % c["p"]
        fields = [str(c["rank"]), ident, p, one_line(c["title"]), one_line(c["url"])]
        if c.get("same_list"):
            fields.append(SAME_LIST)
        lines.append("\t".join(fields))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser, subparsers = build_parser()
    args = parser.parse_args(argv)
    check_args(args, subparsers)
    if args.adapter == "clickup" and args.list_fields is not None:
        try:
            line = run_fields(args)
        except cc_tracker.UsageError as e:
            sys.stderr.write("similar-items.py: %s\n" % e)
            return 2
        except Exception as e:  # never echo a value that might carry a credential
            sys.stderr.write("similar-items.py: internal error (%s)\n" % type(e).__name__)
            return 1
        sys.stdout.buffer.write(line.encode("utf-8"))
        sys.stdout.flush()
        return 0
    try:
        cc_tracker.judge_url()
        if args.adapter == "clickup":
            cc_tracker.clickup_base()
        try:
            res = lookup(args)
        except Unavailable as e:
            res = unavailable(e)
    except cc_tracker.UsageError as e:
        sys.stderr.write("similar-items.py: %s\n" % e)
        return 2
    except Exception as e:  # never echo a value that might carry a credential
        sys.stderr.write("similar-items.py: internal error (%s)\n" % type(e).__name__)
        return 1
    if args.format == "json":
        out = json.dumps(res, ensure_ascii=False) + "\n"
    else:
        out = render_text(res, args.adapter)
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
