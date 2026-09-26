#!/usr/bin/env python3
"""Find open tracker items similar to one issue or to a draft.

    similar-items.py github [--repo OWNER/NAME] (--issue N | --title T --body-file F) [common]
    similar-items.py file   --corpus FILE.json   (--issue N | --title T --body-file F) [common]
    common: [--format text|json] [--lexical-only] [--replay-log FILE [--replay-tag-prefix P]]
            [--question measured|generic] [--log PATH] [--patient]

Every open item is scored against the query by lexical overlap, the top 20
are judged pair by pair by a type-decision classification model, and the top
3 of the re-ranked list are printed with their probability. It only PRESENTS
candidates: nothing here writes to a tracker, and nothing blocks or delays the
registration or the start of work that called it.

Exit codes: 0 for every lookup outcome (semantic, partial, lexical,
unavailable), 2 for a usage error, 1 for an internal error. A lookup that could
not run is `status=unavailable` with exit 0, so the caller carries on.

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

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import cc_tracker  # noqa: E402

GH_LIMIT = 3000
GH_TIMEOUT = 60
GH_FIELDS = "number,title,body,url"

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
    sub = parser.add_subparsers(dest="adapter", metavar="{github,file}")
    sub.required = True
    gh = sub.add_parser("github", parents=[query, common], allow_abbrev=False)
    gh.add_argument("--repo")
    fl = sub.add_parser("file", parents=[query, common], allow_abbrev=False)
    fl.add_argument("--corpus", required=True)
    return parser, {"github": gh, "file": fl}


def check_args(args, subparsers):
    sp = subparsers[args.adapter]
    draft = args.title is not None or args.body_file is not None
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
    question = args.question or "measured"
    if args.adapter == "github":
        source, corpus, truncated, limit, query = github_corpus(args)
    else:
        source, corpus, truncated, limit, query = file_corpus(args)
    if query is None:
        query = {"id": None, "title": args.title, "body": read_text(args.body_file), "url": ""}

    ranked, _overlaps, shared = cc_tracker.shortlist(query, corpus)
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
        candidates.append({"rank": rank, "id": item["id"], "title": item["title"], "url": item["url"],
                           "lexical": i + 1, "p": p})
    return {
        "status": status, "source": source, "corpus": len(corpus), "shortlist": k, "judged": judged,
        "model": cc_tracker.MODEL if status != "lexical" else "-",
        "reason": ",".join(reasons), "notice": " · ".join(notices), "candidates": candidates,
    }


def unavailable(exc):
    return {"status": "unavailable", "source": exc.source, "corpus": 0, "shortlist": 0, "judged": 0,
            "model": "-", "reason": exc.reason, "notice": NOTICE[exc.reason], "candidates": []}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def one_line(s):
    return re.sub(r"[\t\r\n]+", " ", str(s))


def render_text(res):
    lines = ["similar-items: status=%s source=%s corpus=%d shortlist=%d judged=%d model=%s" % (
        res["status"], res["source"], res["corpus"], res["shortlist"], res["judged"], res["model"])]
    if res["notice"]:
        lines.append("notice: " + res["notice"])
    for c in res["candidates"][:cc_tracker.SHOWN]:
        ident = "#%s" % c["id"] if isinstance(c["id"], int) or str(c["id"]).isdigit() else str(c["id"])
        p = "-" if c["p"] is None else "%.2f" % c["p"]
        lines.append("\t".join([str(c["rank"]), ident, p, one_line(c["title"]), one_line(c["url"])]))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser, subparsers = build_parser()
    args = parser.parse_args(argv)
    check_args(args, subparsers)
    try:
        cc_tracker.judge_url()
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
        out = render_text(res)
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
