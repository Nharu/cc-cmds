"""Shared pieces of the issue-tracker helpers in this directory.

Imported by the executables beside it, never run on its own. Standard library
only, Python 3.9 syntax.

What lives here: reading the judgment key and the ClickUp token from the
credential store, the ClickUp GET used to fetch a corpus, the lexical
tokenizer / IDF / overlap that picks the shortlist, building and sending one
pair-judgment request, and replaying a recorded judgment log. No tracker write
lives here: the one ClickUp POST is in `clickup-create.py` alone.

The tokenizer, the IDF and the request bytes are defined to match the
recorded measurement byte for byte. The request hash of every recorded pair
is reproduced only with `json.dumps` defaults (no separators, no
`ensure_ascii=False`, no `sort_keys`), and the recorded shortlists are
reproduced only with this exact tokenizer. Tidying either one breaks replay.
"""
import hashlib
import http.client
import json
import math
import os
import re
import socket
import stat
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

MODEL = "jev-1.13.0"
JUDGE_URL = "https://api.typesafe.ai/v1/systemone"
KEY_FILE = "typesafe.env"
KEY_VAR = "TYPESAFE_API_KEY"

CLICKUP_URL = "https://api.clickup.com/api/v2"
CLICKUP_FILE = "clickup.env"
CLICKUP_VARS = ("CLICKUP_API_TOKEN", "CLICKUP_TOKEN")
CLICKUP_LIMIT = 2000
CLICKUP_PAGE_TIMEOUT = 15.0
CLICKUP_TOTAL_TIMEOUT = 60.0

SHORTLIST = 20
SHOWN = 3
WORKERS = 8

TEXT_CAP = 4000
BODY_CAP = 3500
TOKEN_RE = re.compile(r"[0-9A-Za-z_\-./가-힣]{2,}")

# The recorded measurement's wording, byte for byte, including the repository
# description it carries. Changing one character loses the replay proof.
MEASURED_INSTRUCTIONS = (
    "`issue_a` and `issue_b` are two open defect issues in the same tooling repository (an unattended "
    "coding-agent pipeline). Do they concern the same defect or the same place in the system — close "
    "enough that whoever picks up one should look at the other, or that they would sensibly be fixed "
    "together? Two issues that merely share the repository, the general subsystem, or a failure style "
    "such as 'this fails silently' are NOT the same place.")

GENERIC_INSTRUCTIONS = (
    "`item_a` and `item_b` are two open work items (issues or tickets) in the same project tracker. "
    "Do they concern the same defect or the same place in the system — close enough that whoever picks "
    "up one should look at the other, or that they would sensibly be handled together? Two items that "
    "merely share the project, the general subsystem, or a failure style such as 'this fails silently' "
    "are NOT the same place.")

QUESTIONS = {
    "measured": (("issue_a", "issue_b"), MEASURED_INSTRUCTIONS),
    "generic": (("item_a", "item_b"), GENERIC_INSTRUCTIONS),
}

RETRY_CODES = (429, 529, 500, 502, 503)
REJECT_CODES = (401, 403, 422)


class UsageError(Exception):
    """A caller mistake; the executables turn it into exit code 2."""


class TrackerError(Exception):
    """A tracker read that did not produce a usable answer.

    The message names the failure kind only; it never carries the token or a
    response body.
    """


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

def cred_store():
    return os.environ.get("CC_CMDS_CRED_STORE") or os.path.join(os.path.expanduser("~"), ".config", "cc-cmds")


def usable_cred_file(path):
    """'absent', 'invalid' or 'ok' for a credential file.

    The same condition `credentials.sh store-has` applies: a regular file whose
    mode is exactly 600. `lstat` so a symlink is not regular, matching the
    `-rw-------` string that check compares.
    """
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "absent"
    except OSError:
        return "invalid"
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600:
        return "invalid"
    return "ok"


def read_judge_key():
    """(key, reason). reason is None, 'key-absent' or 'key-invalid'.

    The value lives only in the returned variable. No path here prints a line
    of the file, so a malformed file cannot leak into output or a log.
    """
    path = os.path.join(cred_store(), KEY_FILE)
    state = usable_cred_file(path)
    if state == "absent":
        return None, "key-absent"
    if state != "ok":
        return None, "key-invalid"
    prefix = KEY_VAR + "="
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith(prefix):
                    value = line[len(prefix):].strip().strip('"')
                    if value:
                        return value, None
                    return None, "key-invalid"
    except (OSError, UnicodeDecodeError):
        return None, "key-invalid"
    return None, "key-invalid"


def read_clickup_token():
    """(token, reason). reason is None, 'tracker-key' or 'tracker-key-invalid'.

    `CLICKUP_API_TOKEN=` is looked for first, then `CLICKUP_TOKEN=`; with
    neither, a file holding exactly one non-empty line without `=` is taken as
    the bare token, so a token file moved into the store as it was still works.
    The same file condition as the judgment key applies. No path here prints a
    line of the file.
    """
    path = os.path.join(cred_store(), CLICKUP_FILE)
    state = usable_cred_file(path)
    if state == "absent":
        return None, "tracker-key"
    if state != "ok":
        return None, "tracker-key-invalid"
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return None, "tracker-key-invalid"
    for var in CLICKUP_VARS:
        prefix = var + "="
        for line in lines:
            if line.startswith(prefix):
                value = line[len(prefix):].strip().strip('"')
                return (value, None) if value else (None, "tracker-key")
    bare = [line.strip() for line in lines if line.strip() and "=" not in line]
    if len(bare) == 1:
        return bare[0], None
    return None, "tracker-key"


def loopback_override(var, default):
    """An endpoint override is for tests only, and only toward this machine.

    Anything else would let an environment variable send the real key to an
    arbitrary host.
    """
    value = os.environ.get(var)
    if not value:
        return default
    if value.startswith("http://127.0.0.1:") or value.startswith("http://localhost:"):
        return value
    raise UsageError(var + " accepts only http://127.0.0.1:<port> or http://localhost:<port>")


def judge_url():
    return loopback_override("CC_SIMILAR_JEV_URL", JUDGE_URL)


def clickup_base():
    return loopback_override("CC_SIMILAR_CLICKUP_URL", CLICKUP_URL)


# ---------------------------------------------------------------------------
# Lexical shortlist
# ---------------------------------------------------------------------------

def tokens(title, body):
    text = (title + "\n" + (body or ""))[:TEXT_CAP].lower()
    return set(TOKEN_RE.findall(text))


def shortlist(query, corpus, limit=SHORTLIST):
    """Return (ranked, overlaps, shared) for the query against the corpus.

    `query` and each corpus item are dicts with `id`, `title`, `body`. IDF is
    taken over the corpus plus the query; a query that is itself a corpus item
    is counted once. The query's own item is excluded, the rest keep corpus
    order and are stably sorted by descending overlap.
    """
    qid = query.get("id")
    in_corpus = qid is not None and any(item["id"] == qid for item in corpus)
    toks = [tokens(item["title"], item["body"]) for item in corpus]
    qtok = tokens(query["title"], query["body"])
    df = {}
    for s in toks:
        for w in s:
            df[w] = df.get(w, 0) + 1
    n = len(corpus)
    if not in_corpus:
        n += 1
        for w in qtok:
            df[w] = df.get(w, 0) + 1
    idf = {w: math.log(n / (1 + c)) for w, c in df.items()}
    rest = [(i, item) for i, item in enumerate(corpus) if qid is None or item["id"] != qid]
    scored = []
    for i, item in rest:
        common = qtok & toks[i]
        scored.append((item, sum(idf[w] for w in common), bool(common)))
    scored.sort(key=lambda t: -t[1])
    top = scored[:limit]
    return [t[0] for t in top], [t[1] for t in top], [t[2] for t in top]


# ---------------------------------------------------------------------------
# Pair judgment
# ---------------------------------------------------------------------------

def request_body(query, cand, question):
    """The exact bytes sent for one pair. The query is side a, the candidate b.

    No item number is carried: a candidate that carried its number would match
    a query citing `#N` for free.
    """
    (ka, kb), instructions = QUESTIONS[question]

    def one(item):
        return {"title": item["title"], "body": (item["body"] or "")[:BODY_CAP]}

    return json.dumps({"state": {ka: one(query), kb: one(cand)}, "model": MODEL,
                       "questions": {"same_place": {"type": "noul", "instructions": instructions}}}).encode()


def request_hash(body):
    return hashlib.sha256(body).hexdigest()[:16]


def read_answer(resp):
    """(p, model) from a decoded response, or (None, model) when unusable."""
    if not isinstance(resp, dict):
        return None, None
    model = resp.get("model")
    try:
        p = resp["answers"]["same_place"]["noul"]
    except (KeyError, TypeError):
        return None, model
    if isinstance(p, bool) or not isinstance(p, (int, float)) or not 0 <= p <= 1:
        return None, model
    return float(p), model


class Budget:
    """Time budget for the judgment step.

    The interactive default keeps the wait in front of an issue registration
    short: 15 s per attempt, two retries (1 s then 2 s), a 30 s deadline for
    the whole step. `patient` is for a live measurement only and raises the
    budget to the measurement client's level; the request bytes do not change.
    """

    def __init__(self, patient=False):
        if patient:
            self.attempt = 60.0
            self.tries = 7
            self.waits = [min(2 ** n, 30) for n in range(6)]
            self.deadline = 900.0
        else:
            self.attempt = 15.0
            self.tries = 3
            self.waits = [1, 2]
            self.deadline = 30.0
        self.retry_after_cap = 5.0


def _retry_after(err, cap):
    value = err.headers.get("Retry-After") if err.headers is not None else None
    try:
        return max(0.0, min(float(value), cap))
    except (TypeError, ValueError):
        return None


def opener_for(url):
    """A loopback endpoint bypasses any proxy from the environment."""
    if url.startswith("http://127.0.0.1:") or url.startswith("http://localhost:"):
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener()


def clickup_get(path, token, timeout):
    """GET one ClickUp API path (query string included) and decode its JSON.

    The token goes in `Authorization` as it is, with no `Bearer` in front.
    Every failure - an HTTP error, a network error, a timeout, a body that is
    not JSON - is raised as one TrackerError.
    """
    base = clickup_base()
    req = urllib.request.Request(base + path, method="GET", headers={"Authorization": token})
    try:
        with opener_for(base).open(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise TrackerError("http:%s" % e.code)
    except (urllib.error.URLError, socket.timeout, OSError, http.client.HTTPException):
        raise TrackerError("net")
    try:
        return json.loads(raw)
    except ValueError:
        raise TrackerError("json")


def _send_one(opener, url, key, body, budget, end):
    """Send one pair. Returns (resp or None, failure or None).

    failure is ('reject', code), ('http', code), ('net', None) or
    ('timeout', None).
    """
    last = ("net", None)
    for attempt in range(budget.tries):
        left = end - time.monotonic()
        if left <= 0:
            return None, ("timeout", None)
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": "Bearer " + key, "Content-Type": "application/json"})
        try:
            with opener.open(req, timeout=min(budget.attempt, left)) as r:
                raw = r.read()
            try:
                return json.loads(raw), None
            except ValueError:
                return None, ("http", 200)
        except urllib.error.HTTPError as e:
            code = e.code
            if code in REJECT_CODES:
                return None, ("reject", code)
            if code not in RETRY_CODES:
                return None, ("http", code)
            last = ("http", code)
            wait = _retry_after(e, budget.retry_after_cap)
        except (urllib.error.URLError, socket.timeout, OSError, http.client.HTTPException):
            last = ("net", None)
            wait = None
        if attempt + 1 >= budget.tries:
            break
        if wait is None:
            wait = budget.waits[min(attempt, len(budget.waits) - 1)]
        if time.monotonic() + wait >= end:
            return None, ("timeout", None)
        time.sleep(wait)
    if time.monotonic() >= end:
        return None, ("timeout", None)
    return None, last


class LogWriter:
    """Appends one JSONL record per judged pair. Never carries a credential."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, tag, req_sha, resp, failure):
        if not self.path:
            return
        rec = {"tag": tag, "req_sha": req_sha}
        if resp is not None:
            rec["resp"] = resp
        if failure is not None:
            rec["error"] = failure[0] if failure[1] is None else "%s:%s" % failure
        with self.lock, open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def judge_live(query, cands, question, key, budget, log):
    """Judge every candidate against the query over HTTP, 8 in parallel.

    Returns one (p, model, failure) per candidate, in candidate order.
    """
    url = judge_url()
    opener = opener_for(url)
    end = time.monotonic() + budget.deadline

    def run(cand):
        body = request_body(query, cand, question)
        resp, failure = _send_one(opener, url, key, body, budget, end)
        p = model = None
        if resp is not None:
            p, model = read_answer(resp)
            if p is None:
                failure = ("http", 200)
        log.write("%s:%s" % (query.get("id"), cand["id"]), request_hash(body), resp, failure)
        return p, model, failure

    with ThreadPoolExecutor(WORKERS) as ex:
        return list(ex.map(run, cands))


def load_replay(path):
    """req_sha -> list of (tag, resp), in file order."""
    recs = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            recs.setdefault(rec.get("req_sha"), []).append((str(rec.get("tag", "")), rec.get("resp")))
    return recs


def judge_replay(query, cands, question, recs, prefix, log):
    """Answer each pair from a recorded log instead of sending it.

    The request is built exactly as for a live send and hashed; the answer is
    the first record with that hash whose tag starts with `prefix`. The same
    pair can sit in the log under two tags with different answers, which is
    what the prefix chooses between. No transport is built on this path.
    """
    out = []
    for cand in cands:
        body = request_body(query, cand, question)
        sha = request_hash(body)
        resp = None
        for tag, r in recs.get(sha, ()):
            if tag.startswith(prefix):
                resp = r
                break
        p = model = None
        failure = None
        if resp is None:
            failure = ("replay-miss", None)
        else:
            p, model = read_answer(resp)
            if p is None:
                failure = ("http", 200)
        log.write("%s:%s" % (query.get("id"), cand["id"]), sha, resp, failure)
        out.append((p, model, failure))
    return out
