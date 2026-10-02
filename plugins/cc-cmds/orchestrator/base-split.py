#!/usr/bin/env python3
"""Check a base design document, plan its ticket publication, and record it.

    base-split.py check  DOC
    base-split.py plan   DOC --row ROW --out DIR [--tracker T] [--target X]
    base-split.py record DOC --row ROW (--doc-only
                                       | --entry ID --plan FILE [--state S] [--ref R]
                                         [--node-id N] [--similar LIST])

A base design document is the upper design of a piece of work that is cut
into several tickets; its grammar, the predicates below, the issue-body rules
and the registry format are defined once in `skills/_common/base-design.md`.

`check` prints one line `<predicate> <detail>` per violation of D0 (the
discriminator), P1 (graph shape), P2 (edges and contracts), P3 (file
disjointness), P4 (critical path and width) and B1 (issue-body lint). It reads
only.

`plan` writes each `**발행 본문**` byte for byte to `DIR/body-*.md`, reads it
back, and writes `DIR/plan.jsonl` — one entry per line, in execution order
(base first, then by dependency layer, contract tickets first inside a layer,
then by number). An entry is `create`, `edit` or `relate` with the exact argv
to run, `resolve` (a ticket the registry left in flight, to be settled by an
exact-title read), or `wait` (its argv needs a reference that does not exist
yet). The caller runs the argvs as given, records each result with `record`,
and calls `plan` again until no `wait` is left; it never builds an argv. A row
with `트래커=없음`, a row that disagrees with `--tracker`/`--target`, a
registry recorded against other document bytes, or any check violation makes
`plan` refuse with no write command at all.

`record` writes the registry `<doc dir>/design-base/<doc stem>.tickets.md` —
the only writer of that file. Writing the same row twice yields the same bytes.

Exit codes: 0 success, 1 check violation or internal error, 2 usage error,
3 refused (plan or record would contradict the row, the registry or the
document; nothing was written).

Run it by path, with no interpreter in front: the gate grades the basename
and the subcommand, and an interpreter prefix is graded as an opaque write.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
import tempfile  # noqa: E402

KIND_LINE = "**문서 종류**: 베이스 설계"
SPLIT_HEADING = "## 티켓 분할"
SLICING_HEADING = "## 구현 슬라이싱"
CONTRACT_SECTION = "## 티켓 간 계약"
MAX_TICKETS = 100
MAX_DEPTH = 2

REGISTRY_VERSION = "cc-design-base-tickets v1"
REGISTRY_END = "<!-- cc-design-base-tickets: end -->"

TICKET_FIELDS = ("종류", "레포", "선행", "제공 계약", "소비 계약", "소유 파일",
                 "공유 파일", "범위", "발행 제목", "발행 본문")
CONTRACT_FIELDS = ("제공 티켓", "소비 티켓", "형태", "인터페이스")
FENCED_FIELDS = ("인터페이스", "발행 본문")
GLOB_META = "*?[{"

FIELD_RE = re.compile(r"^\*\*([^*]+)\*\*:(?: (.*))?$")
FENCE_OPEN_RE = re.compile(r"^(`{3,})(.*)$")
TICKET_HEAD_RE = re.compile(r"^### 티켓 (T(\d+)) — (.+)$")
CONTRACT_HEAD_RE = re.compile(r"^### 계약 (C(\d+)) — (.+)$")
TICKET_ID_RE = re.compile(r"^T(\d+)$")
CONTRACT_ID_RE = re.compile(r"^C(\d+)$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

B1_PATTERNS = (
    ("문서 경로", re.compile(r"docs/")),
    ("문서 경로", re.compile(r"[A-Za-z0-9_./-]\.md(?![A-Za-z0-9])")),
    ("라벨", re.compile(r"(?<![A-Za-z0-9])[TC][0-9]+(?![0-9])")),
    ("라벨", re.compile("§")),
    ("표제 줄", re.compile(r"(?m)^ {0,3}#{1,6}(?:[ \t]|$)")),
)

ROW_RE = re.compile(r"^- `베이스 발행` \| 트래커=(github|clickup|없음) \| 대상=(\S+)$")
REG_HEAD_RE = re.compile(
    r"^<!-- cc-design-base-tickets v1; doc=([^;]+); doc-sha256=([0-9a-f]{64}); "
    r"tracker=(github|clickup|없음); target=([^;]+) -->$")
REG_BASE_RE = re.compile(r"^- `베이스` \| 상태=(발행중|발행됨|문서만) \| 참조=(\S+) \| 노드 id=(\S+)$")
REG_TICKET_RE = re.compile(
    r"^- `티켓` \| id=(T\d+) \| 상태=(발행중|발행됨|문서만) \| 참조=(\S+) \| 노드 id=(\S+) \| 유사 후보=(.+)$")
REG_REL_RE = re.compile(r"^- `관계` \| 종류=(하위|선행) \| 원=(T\d+) \| 대상=(T\d+|베이스) \| 상태=(대기|걸림|문서만)$")


class Refused(Exception):
    """The command would contradict the row, the registry or the document."""


class UsageError(Exception):
    """The input cannot be read as asked."""


# --------------------------------------------------------------------------
# Document parsing
# --------------------------------------------------------------------------

def split_lines(text):
    """Lines without their terminators; a final newline adds no empty line."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def mark_fences(lines):
    """For each line, whether it sits inside (or on the delimiter of) a fence."""
    inside = []
    open_len = 0
    for line in lines:
        if open_len:
            inside.append(True)
            m = re.match(r"^(`{3,})\s*$", line)
            if m and len(m.group(1)) >= open_len:
                open_len = 0
            continue
        m = FENCE_OPEN_RE.match(line)
        if m:
            inside.append(True)
            open_len = len(m.group(1))
            continue
        inside.append(False)
    return inside


def fenced_value(lines, i):
    """Content of the fence opening at line i, or None when line i opens none."""
    if i >= len(lines):
        return None
    m = FENCE_OPEN_RE.match(lines[i])
    if not m:
        return None
    n = len(m.group(1))
    body = []
    for j in range(i + 1, len(lines)):
        c = re.match(r"^(`{3,})\s*$", lines[j])
        if c and len(c.group(1)) >= n:
            return "".join(x + "\n" for x in body)
        body.append(lines[j])
    return None


def parse_block(lines, inside, start, end):
    """Field lines of one `###` block, outside fences, first value wins."""
    fields = {}
    for i in range(start, end):
        if inside[i]:
            continue
        m = FIELD_RE.match(lines[i])
        if not m:
            continue
        key, value = m.group(1), (m.group(2) or "")
        if key in fields:
            continue
        if key in FENCED_FIELDS and value == "":
            v = fenced_value(lines, i + 1)
            fields[key] = v
        else:
            fields[key] = value.strip()
    return fields


def split_list(value):
    if value is None:
        return []
    value = value.strip()
    if value in ("", "없음"):
        return []
    return [x.strip() for x in value.split(",") if x.strip()]


def strip_code(item):
    item = item.strip()
    if len(item) >= 2 and item.startswith("`") and item.endswith("`"):
        return item[1:-1]
    return item


class Doc(object):
    def __init__(self, path):
        self.path = path
        try:
            with open(path, "rb") as f:
                self.raw = f.read()
        except OSError as e:
            raise UsageError("cannot read %s (%s)" % (path, type(e).__name__))
        try:
            text = self.raw.decode("utf-8")
        except UnicodeDecodeError:
            raise UsageError("%s is not UTF-8" % path)
        self.sha256 = hashlib.sha256(self.raw).hexdigest()
        self.lines = split_lines(text)
        self.inside = mark_fences(self.lines)
        self.kind_line = False
        self.split_heading = False
        self.slicing_heading = False
        self.header = {}
        self.base = None
        self.tickets = []      # [(id, num, title, fields)]
        self.contracts = []    # [(id, num, title, fields)]
        self.parse()

    def parse(self):
        lines, inside = self.lines, self.inside
        heads = []  # (index, level, text)
        for i, line in enumerate(lines):
            if inside[i]:
                continue
            if line == KIND_LINE:
                self.kind_line = True
            if line.startswith("## ") or line.startswith("### "):
                level = 2 if line.startswith("## ") else 3
                heads.append((i, level, line))
                if line == SPLIT_HEADING:
                    self.split_heading = True
                if line == SLICING_HEADING:
                    self.slicing_heading = True
        section = None
        for k, (i, level, text) in enumerate(heads):
            end = heads[k + 1][0] if k + 1 < len(heads) else len(lines)
            if level == 2:
                section = text
                if text == SPLIT_HEADING:
                    sub_end = end
                    self.header = parse_block(lines, inside, i + 1, sub_end)
                continue
            if section == SPLIT_HEADING:
                if text == "### 베이스 티켓":
                    self.base = parse_block(lines, inside, i + 1, end)
                    continue
                m = TICKET_HEAD_RE.match(text)
                if m:
                    self.tickets.append((m.group(1), int(m.group(2)), m.group(3),
                                         parse_block(lines, inside, i + 1, end)))
            elif section == CONTRACT_SECTION:
                m = CONTRACT_HEAD_RE.match(text)
                if m:
                    self.contracts.append((m.group(1), int(m.group(2)), m.group(3),
                                           parse_block(lines, inside, i + 1, end)))


# --------------------------------------------------------------------------
# Graph helpers
# --------------------------------------------------------------------------

def glob_prefix(path):
    cut = len(path)
    for ch in GLOB_META:
        k = path.find(ch)
        if k != -1 and k < cut:
            cut = k
    return path[:cut], cut < len(path)


def paths_overlap(a, b):
    pa, ga = glob_prefix(a)
    pb, gb = glob_prefix(b)
    if not ga and not gb:
        return a == b
    return pa.startswith(pb) or pb.startswith(pa)


def file_overlaps(t1, t2):
    """(repo, path) pairs of t1 and t2 that overlap, both shared lists removed."""
    if t1["repo"] != t2["repo"]:
        return []
    shared = set(t1["shared"]) | set(t2["shared"])
    a = [p for p in t1["owned"] if p not in shared]
    b = [p for p in t2["owned"] if p not in shared]
    hits = []
    for p in a:
        for q in b:
            if paths_overlap(p, q):
                hits.append(p if p == q else "%s~%s" % (p, q))
    return hits


class Graph(object):
    """The ticket graph as read from the document, with what P1 found."""

    def __init__(self, doc):
        self.doc = doc
        self.v = []
        self.ids = []
        self.t = {}
        self.c = {}
        self.cyclic = False
        self.build()

    def add(self, pred, detail):
        self.v.append((pred, detail))

    def build(self):
        doc = self.doc
        seen = set()
        for tid, num, title, f in doc.tickets:
            if tid in seen:
                self.add("P1", "티켓 id 중복 %s" % tid)
                continue
            seen.add(tid)
            for key in TICKET_FIELDS:
                if f.get(key) is None:
                    self.add("P1", "%s 필드 없음 %s" % (tid, key))
            self.ids.append(tid)
            self.t[tid] = {
                "num": num, "title": title, "kind": f.get("종류") or "",
                "repo": f.get("레포") or "",
                "deps": split_list(f.get("선행")),
                "provides": split_list(f.get("제공 계약")),
                "consumes": split_list(f.get("소비 계약")),
                "owned": [strip_code(x) for x in split_list(f.get("소유 파일"))],
                "shared": [strip_code(x) for x in split_list(f.get("공유 파일"))],
                "nesting": bool((f.get("중첩 사유") or "").strip()),
                "pub_title": f.get("발행 제목"), "body": f.get("발행 본문"),
            }
            if self.t[tid]["kind"] not in ("계약", "구현"):
                self.add("P1", "%s 종류 값 %s" % (tid, self.t[tid]["kind"] or "(빈 값)"))
        cseen = set()
        for cid, num, title, f in doc.contracts:
            if cid in cseen:
                self.add("P1", "계약 id 중복 %s" % cid)
                continue
            cseen.add(cid)
            for key in CONTRACT_FIELDS:
                if f.get(key) is None:
                    self.add("P1", "%s 필드 없음 %s" % (cid, key))
            self.c[cid] = {"providers": split_list(f.get("제공 티켓")),
                           "consumers": split_list(f.get("소비 티켓"))}
        if doc.base is None:
            self.add("P1", "베이스 티켓 블록 없음")
        else:
            for key in ("발행 제목", "발행 본문"):
                if doc.base.get(key) is None:
                    self.add("P1", "베이스 티켓 필드 없음 %s" % key)

        # every reference resolves
        for tid in self.ids:
            t = self.t[tid]
            t["deps"] = self.resolve_tickets(t["deps"], "%s 선행" % tid)
            t["provides"] = self.resolve_contracts(t["provides"], "%s 제공 계약" % tid)
            t["consumes"] = self.resolve_contracts(t["consumes"], "%s 소비 계약" % tid)
        for cid in sorted(self.c, key=lambda x: int(x[1:])):
            c = self.c[cid]
            c["providers"] = self.resolve_tickets(c["providers"], "%s 제공 티켓" % cid)
            c["consumers"] = self.resolve_tickets(c["consumers"], "%s 소비 티켓" % cid)
            if len(c["providers"]) != 1:
                self.add("P1", "%s 제공 티켓 %d개 (정확히 하나여야 함)" % (cid, len(c["providers"])))
            for p in c["providers"]:
                if cid not in self.t[p]["provides"]:
                    self.add("P1", "%s 의 제공 티켓 %s 가 제공 계약에 적지 않음" % (cid, p))
        for tid in self.ids:
            for cid in self.t[tid]["provides"]:
                if tid not in self.c[cid]["providers"]:
                    self.add("P1", "%s 가 제공 계약에 적은 %s 의 제공 티켓이 아님" % (tid, cid))

        declared = self.doc.header.get("티켓 수")
        if declared is None:
            self.add("P1", "티켓 수 선언 없음")
        elif not re.match(r"^[0-9]+$", declared) or int(declared) != len(doc.tickets):
            self.add("P1", "티켓 수 선언 %s ≠ 블록 %d" % (declared, len(doc.tickets)))
        if len(self.ids) > MAX_TICKETS:
            self.add("P1", "티켓 %d개 (상한 %d)" % (len(self.ids), MAX_TICKETS))

        cycle = self.find_cycle()
        if cycle:
            self.cyclic = True
            self.add("P1", "선행 순환 %s" % " → ".join(cycle))

    def resolve_tickets(self, items, where):
        out = []
        for x in items:
            if TICKET_ID_RE.match(x) and x in self.t:
                if x not in out:
                    out.append(x)
            else:
                self.add("P1", "%s 참조 해소 안 됨 %s" % (where, x))
        return out

    def resolve_contracts(self, items, where):
        out = []
        for x in items:
            if CONTRACT_ID_RE.match(x) and x in self.c:
                if x not in out:
                    out.append(x)
            else:
                self.add("P1", "%s 참조 해소 안 됨 %s" % (where, x))
        return out

    def find_cycle(self):
        color = {}
        stack = []

        def visit(u):
            color[u] = 1
            stack.append(u)
            for w in self.t[u]["deps"]:
                if color.get(w) == 1:
                    return stack[stack.index(w):] + [w]
                if color.get(w) is None:
                    r = visit(w)
                    if r:
                        return r
            color[u] = 2
            stack.pop()
            return None

        for u in self.ids:
            if color.get(u) is None:
                r = visit(u)
                if r:
                    return r
        return None

    # The graph is acyclic from here on.
    def ancestors(self):
        memo = {}

        def anc(u):
            if u not in memo:
                s = set()
                for w in self.t[u]["deps"]:
                    s.add(w)
                    s |= anc(w)
                memo[u] = s
            return memo[u]

        return dict((u, anc(u)) for u in self.ids)

    def levels(self):
        memo = {}

        def lvl(u):
            if u not in memo:
                memo[u] = 1 + max([lvl(w) for w in self.t[u]["deps"]] or [0])
            return memo[u]

        return dict((u, lvl(u)) for u in self.ids)

    def order(self):
        """Execution order: by layer, contract tickets first, then by number."""
        lv = self.levels()
        return sorted(self.ids, key=lambda u: (lv[u], 0 if self.t[u]["kind"] == "계약" else 1,
                                               self.t[u]["num"]))


def check_d0(doc):
    out = []
    if not doc.kind_line:
        out.append(("D0", "판별자 줄 없음 %s" % KIND_LINE))
    if not doc.split_heading:
        out.append(("D0", "표제 없음 %s" % SPLIT_HEADING))
    if doc.slicing_heading:
        out.append(("D0", "베이스 문서에 %s 가 있음" % SLICING_HEADING))
    return out


def check_p2(g, anc):
    out = []
    for tid in g.ids:
        t = g.t[tid]
        for cid in t["consumes"]:
            for p in g.c[cid]["providers"]:
                if p != tid and p not in anc[tid]:
                    out.append(("P2", "%s 가 소비하는 %s 의 제공 티켓 %s 에 선행으로 닿지 않음" % (tid, cid, p)))
        for p in t["deps"]:
            by_contract = any(p in g.c[cid]["providers"] for cid in t["consumes"])
            by_nesting = t["nesting"] or g.t[p]["nesting"]
            if not by_contract and not by_nesting:
                out.append(("P2", "병렬성 손실 %s→%s" % (tid, p)))
    return out


def check_p3(g, anc):
    out = []
    for i, a in enumerate(g.ids):
        for b in g.ids[i + 1:]:
            hits = file_overlaps(g.t[a], g.t[b])
            if not hits:
                continue
            ordered = a in anc[b] or b in anc[a]
            where = "%s:%s" % (g.t[a]["repo"], ", ".join(hits))
            if not ordered:
                out.append(("P3", "%s·%s 동시 티켓 소유 파일 중첩 %s" % (a, b, where)))
            elif not (g.t[a]["nesting"] or g.t[b]["nesting"]):
                out.append(("P3", "%s·%s 순서 있는 중첩에 중첩 사유 없음 %s" % (a, b, where)))
    return out


def check_p4(g):
    out = []
    lv = g.levels()
    depth = max(lv.values() or [0])
    decl = g.doc.header.get("임계 경로")
    if decl is None:
        out.append(("P4", "임계 경로 선언 없음"))
    else:
        path = [x.strip() for x in decl.split("→")]
        ok = len(path) == depth and all(x in g.t for x in path)
        if ok:
            ok = lv[path[0]] == 1
            for prev, nxt in zip(path, path[1:]):
                if prev not in g.t[nxt]["deps"]:
                    ok = False
        if not ok:
            out.append(("P4", "임계 경로 선언 %s 이 최장 경로가 아님 (최장 길이 %d)" % (decl, depth)))
    width = 0
    for k in set(lv.values()):
        width = max(width, sum(1 for u in lv if lv[u] == k))
    decl_w = g.doc.header.get("병렬 폭")
    if decl_w is None:
        out.append(("P4", "병렬 폭 선언 없음"))
    elif not re.match(r"^[0-9]+$", decl_w) or int(decl_w) != width:
        out.append(("P4", "병렬 폭 선언 %s ≠ 실제 %d" % (decl_w, width)))
    if depth > MAX_DEPTH and not (g.doc.header.get("깊이 사유") or "").strip():
        out.append(("P4", "깊이 %d 에 깊이 사유 없음" % depth))
    return out


def check_b1(doc):
    out = []
    bodies = []
    if doc.base is not None and doc.base.get("발행 본문") is not None:
        bodies.append(("베이스 티켓", doc.base["발행 본문"]))
    for tid, num, title, f in doc.tickets:
        if f.get("발행 본문") is not None:
            bodies.append((tid, f["발행 본문"]))
    for who, body in bodies:
        for what, rx in B1_PATTERNS:
            m = rx.search(body)
            if m:
                out.append(("B1", "%s 본문에 %s %s" % (who, what, m.group(0).strip() or "#")))
    return out


def run_checks(doc):
    """(violations, graph) — the graph is None only when no ticket parses."""
    v = check_d0(doc)
    g = Graph(doc)
    v.extend(g.v)
    if not g.cyclic:
        anc = g.ancestors()
        v.extend(check_p2(g, anc))
        v.extend(check_p3(g, anc))
        v.extend(check_p4(g))
    v.extend(check_b1(doc))
    seen = set()
    uniq = []
    for item in v:
        if item not in seen:
            seen.add(item)
            uniq.append(item)
    return uniq, g


# --------------------------------------------------------------------------
# Registry
# --------------------------------------------------------------------------

def registry_path(doc_path):
    d = os.path.dirname(os.path.abspath(doc_path))
    stem = os.path.basename(doc_path)
    if stem.endswith(".md"):
        stem = stem[:-3]
    return os.path.join(d, "design-base", stem + ".tickets.md")


def doc_field(doc_path):
    a = os.path.abspath(doc_path)
    return "%s/%s" % (os.path.basename(os.path.dirname(a)), os.path.basename(a))


def parse_row(row):
    m = ROW_RE.match(row.strip())
    if not m:
        raise Refused("베이스 발행 행을 읽지 못함")
    tracker, target = m.group(1), m.group(2)
    if tracker == "없음" and target != "-":
        raise Refused("트래커=없음 인데 대상이 - 가 아님")
    if tracker == "github" and not REPO_RE.match(target):
        raise Refused("github 대상이 owner/name 꼴이 아님")
    if tracker != "없음" and target == "-":
        raise Refused("트래커가 있는데 대상이 -")
    return tracker, target


class Registry(object):
    def __init__(self, doc, tracker, target):
        self.doc = doc
        self.path = registry_path(doc.path)
        self.tracker = tracker
        self.target = target
        self.exists = False
        self.recorded_sha = None
        self.base = None          # (state, ref, node)
        self.tickets = {}         # id -> [state, ref, node, similar]
        self.rels = {}            # (kind, src, dst) -> state

    def load(self):
        if not os.path.exists(self.path):
            return self
        try:
            with open(self.path, "rb") as f:
                text = f.read().decode("utf-8")
        except (OSError, UnicodeDecodeError) as e:
            raise Refused("등록부를 읽지 못함 (%s)" % type(e).__name__)
        lines = split_lines(text)
        if not lines or not lines[0].startswith("<!-- %s; " % REGISTRY_VERSION):
            raise Refused("등록부 머리 판본을 모름")
        m = REG_HEAD_RE.match(lines[0])
        if not m:
            raise Refused("등록부 머리 줄을 읽지 못함")
        if lines[-1] != REGISTRY_END:
            raise Refused("등록부 끝 표지 없음 (잘린 파일)")
        if m.group(3) != self.tracker or m.group(4) != self.target:
            raise Refused("등록부의 트래커·대상(%s, %s)이 행(%s, %s)과 다름"
                          % (m.group(3), m.group(4), self.tracker, self.target))
        self.recorded_sha = m.group(2)
        for line in lines[1:-1]:
            b = REG_BASE_RE.match(line)
            t = REG_TICKET_RE.match(line)
            r = REG_REL_RE.match(line)
            if b:
                self.base = (b.group(1), b.group(2), b.group(3))
            elif t:
                self.tickets[t.group(1)] = [t.group(2), t.group(3), t.group(4), t.group(5)]
            elif r:
                self.rels[(r.group(1), r.group(2), r.group(3))] = r.group(4)
            else:
                raise Refused("등록부에 읽을 수 없는 줄이 있음")
        self.exists = True
        return self

    def require_doc_match(self):
        if self.exists and self.recorded_sha != self.doc.sha256:
            raise Refused("등록부 doc-sha256 이 문서의 현재 sha256 과 다름")

    def render(self, g):
        out = ["<!-- %s; doc=%s; doc-sha256=%s; tracker=%s; target=%s -->"
               % (REGISTRY_VERSION, doc_field(self.doc.path), self.doc.sha256,
                  self.tracker, self.target)]
        if self.base:
            out.append("- `베이스` | 상태=%s | 참조=%s | 노드 id=%s" % self.base)
        for tid in sorted(self.tickets, key=lambda x: int(x[1:])):
            s = self.tickets[tid]
            out.append("- `티켓` | id=%s | 상태=%s | 참조=%s | 노드 id=%s | 유사 후보=%s"
                       % (tid, s[0], s[1], s[2], s[3]))
        for key in sorted(self.rels, key=rel_sort_key):
            out.append("- `관계` | 종류=%s | 원=%s | 대상=%s | 상태=%s" % (key + (self.rels[key],)))
        out.append(REGISTRY_END)
        return "".join(x + "\n" for x in out)

    def fill_relations(self, g, default):
        for tid in g.ids:
            self.rels.setdefault(("하위", tid, "베이스"), default)
            for p in g.t[tid]["deps"]:
                self.rels.setdefault(("선행", tid, p), default)

    def write(self, g):
        data = self.render(g).encode("utf-8")
        d = os.path.dirname(self.path)
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".tickets.", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp, self.path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise


def rel_sort_key(key):
    kind, src, dst = key
    return (0 if kind == "하위" else 1, int(src[1:]), -1 if dst == "베이스" else int(dst[1:]))


# --------------------------------------------------------------------------
# Plan
# --------------------------------------------------------------------------

def write_atomic(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".base-split.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_body(out, name, body):
    path = os.path.join(out, name)
    data = body.encode("utf-8")
    write_atomic(path, data)
    with open(path, "rb") as f:
        back = f.read()
    if back != data:
        raise IOError("body file read back differs")
    return path


def entry(eid, kind, row, argv=None, title=None, why=None):
    e = {"entry": eid, "kind": kind, "row": row, "argv": argv or []}
    if title is not None:
        e["title"] = title
    if why is not None:
        e["why"] = why
    return e


def build_plan(doc, g, reg, out, tracker, target):
    here = os.path.dirname(os.path.realpath(__file__))
    create_tool = os.path.join(here, "clickup-create.py")
    relate_tool = os.path.join(here, "clickup-relate.py")
    entries = []

    def issued(state):
        return state is not None and state[0] == "발행됨"

    def ticket_state(tid):
        return reg.tickets.get(tid)

    def ref_of(tid):
        s = ticket_state(tid)
        return s[1] if issued(s) else None

    def node_of(tid):
        s = ticket_state(tid)
        return s[2] if issued(s) and s[2] != "-" else None

    base_title = doc.base["발행 제목"]
    base_body = write_body(out, "body-base.md", doc.base["발행 본문"])
    base_state = reg.base
    base_ref = base_state[1] if issued(base_state) else None
    base_node = base_state[2] if issued(base_state) and base_state[2] != "-" else None

    if base_state is None:
        if tracker == "github":
            argv = ["gh", "issue", "create", "--repo", target, "--title", base_title,
                    "--body-file", base_body]
        else:
            argv = [create_tool, "--list", target, "--name", base_title,
                    "--description-file", base_body]
        entries.append(entry("base", "create", "베이스", argv, title=base_title))
    elif base_state[0] == "발행중":
        entries.append(entry("base", "resolve", "베이스", title=base_title))

    for tid in g.order():
        t = g.t[tid]
        body = write_body(out, "body-%s.md" % tid, t["body"])
        st = ticket_state(tid)
        if st is not None and st[0] == "발행중":
            entries.append(entry(tid, "resolve", tid, title=t["pub_title"]))
            continue
        if st is None:
            if tracker == "github":
                missing = [p for p in t["deps"] if ref_of(p) is None]
                if base_ref is None or missing:
                    need = (["베이스"] if base_ref is None else []) + missing
                    entries.append(entry(tid, "wait", tid, title=t["pub_title"],
                                         why="참조 없음 " + ", ".join(need)))
                    continue
                argv = ["gh", "issue", "create", "--repo", target, "--title", t["pub_title"],
                        "--body-file", body, "--parent", base_ref]
                if t["deps"]:
                    argv += ["--blocked-by", ",".join(ref_of(p) for p in t["deps"])]
            else:
                if base_node is None:
                    entries.append(entry(tid, "wait", tid, title=t["pub_title"], why="참조 없음 베이스"))
                    continue
                argv = [create_tool, "--list", target, "--name", t["pub_title"],
                        "--description-file", body, "--parent", base_node]
            entries.append(entry(tid, "create", tid, argv, title=t["pub_title"]))
            continue

    # Relations that a creation did not carry: GitHub fills them by edit on a
    # resume, ClickUp makes every dependency with its own call.
    for tid in sorted(g.ids, key=lambda u: g.t[u]["num"]):
        if not issued(ticket_state(tid)):
            if tracker == "clickup":
                for p in g.t[tid]["deps"]:
                    eid = "rel:선행:%s:%s" % (tid, p)
                    entries.append(entry(eid, "wait", "관계 선행 %s %s" % (tid, p), why="참조 없음 %s" % tid))
            continue
        if tracker == "github" and reg.rels.get(("하위", tid, "베이스"), "대기") == "대기":
            if base_ref is not None:
                entries.append(entry("rel:하위:%s:베이스" % tid, "edit", "관계 하위 %s 베이스" % tid,
                                     ["gh", "issue", "edit", ref_of(tid), "--parent", base_ref]))
        for p in g.t[tid]["deps"]:
            if reg.rels.get(("선행", tid, p), "대기") != "대기":
                continue
            eid = "rel:선행:%s:%s" % (tid, p)
            row = "관계 선행 %s %s" % (tid, p)
            if tracker == "github":
                if ref_of(p) is None:
                    entries.append(entry(eid, "wait", row, why="참조 없음 %s" % p))
                else:
                    entries.append(entry(eid, "edit", row,
                                         ["gh", "issue", "edit", ref_of(tid), "--add-blocked-by", ref_of(p)]))
            else:
                if node_of(tid) is None or node_of(p) is None:
                    entries.append(entry(eid, "wait", row, why="참조 없음 %s" % p))
                else:
                    entries.append(entry(eid, "relate", row,
                                         [relate_tool, "--task", node_of(tid), "--depends-on", node_of(p)]))
    return entries


def cmd_check(args):
    doc = Doc(args.doc)
    violations, _ = run_checks(doc)
    for pred, detail in violations:
        sys.stdout.buffer.write(("%s %s\n" % (pred, detail)).encode("utf-8"))
    sys.stdout.flush()
    return 1 if violations else 0


def refuse_plan(out, why):
    write_atomic(os.path.join(out, "plan.jsonl"), b"")
    sys.stdout.buffer.write(("거절 %s\n" % why).encode("utf-8"))
    sys.stdout.flush()
    return 3


def cmd_plan(args):
    doc = Doc(args.doc)
    out = os.path.abspath(args.out.rstrip("/") or "/")
    try:
        os.makedirs(out, exist_ok=True)
    except OSError as e:
        raise UsageError("cannot create %s (%s)" % (args.out, type(e).__name__))
    try:
        tracker, target = parse_row(args.row)
    except Refused as e:
        return refuse_plan(out, str(e))
    if args.tracker is not None and args.tracker != tracker:
        return refuse_plan(out, "--tracker %s 가 행의 트래커 %s 와 다름" % (args.tracker, tracker))
    if args.target is not None and args.target != target:
        return refuse_plan(out, "--target 이 행의 대상과 다름")
    if tracker == "없음":
        return refuse_plan(out, "트래커=없음 — 쓰기 명령을 내지 않음 (record --doc-only)")
    violations, g = run_checks(doc)
    if violations:
        return refuse_plan(out, "점검 위반 %d건 — check 로 확인" % len(violations))
    try:
        reg = Registry(doc, tracker, target).load()
        reg.require_doc_match()
    except Refused as e:
        return refuse_plan(out, str(e))
    entries = build_plan(doc, g, reg, out, tracker, target)
    data = "".join(json.dumps(e, ensure_ascii=False, sort_keys=True) + "\n" for e in entries)
    write_atomic(os.path.join(out, "plan.jsonl"), data.encode("utf-8"))
    lines = []
    for e in entries:
        argv = " ".join(shlex.quote(a) for a in e["argv"]) if e["argv"] else "-"
        lines.append("%s\t%s\t%s\t%s\n" % (e["entry"], e["kind"], e["row"], argv))
    if not entries:
        lines.append("계획 항목 없음 — 등록부가 모두 발행됨\n")
    sys.stdout.buffer.write("".join(lines).encode("utf-8"))
    sys.stdout.flush()
    return 0


# --------------------------------------------------------------------------
# Record
# --------------------------------------------------------------------------

def load_entry(plan_path, eid):
    try:
        with open(plan_path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise UsageError("cannot read %s (%s)" % (plan_path, type(e).__name__))
    for line in split_lines(text):
        if not line.strip():
            continue
        e = json.loads(line)
        if e.get("entry") == eid:
            return e
    raise Refused("계획에 항목 %s 가 없음" % eid)


def flag_values(argv, flag):
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None


def check_value(value, what):
    if value is None:
        return
    if value == "" or "\n" in value or " | " in value or (what != "유사 후보" and " " in value):
        raise Refused("%s 값을 등록부에 쓸 수 없음" % what)


def record_entry(args, doc, g, reg, tracker):
    e = load_entry(args.plan, args.entry)
    kind, row = e.get("kind"), e.get("row") or ""
    if kind == "wait":
        raise Refused("wait 항목은 기록하지 않음 — plan 을 다시 부를 것")
    check_value(args.ref, "참조")
    check_value(args.node_id, "노드 id")
    check_value(args.similar, "유사 후보")
    if args.state is None and args.similar is None:
        raise Refused("--state 나 --similar 중 하나가 필요함")

    if kind in ("edit", "relate"):
        if args.state != "발행됨" or args.similar is not None:
            raise Refused("관계 항목은 --state 발행됨 으로만 기록함")
        parts = row.split(" ")
        key = (parts[1], parts[2], parts[3])
        if key not in reg.rels:
            raise Refused("등록부에 없는 관계 %s" % row)
        reg.rels[key] = "걸림"
        return

    if row == "베이스":
        if args.similar is not None:
            raise Refused("베이스 행에는 유사 후보 칸이 없음")
        cur = reg.base
        reg.base = transition(cur, args, tracker, kind)
        return

    tid = row
    if tid not in g.t:
        raise Refused("문서에 없는 티켓 %s" % tid)
    cur = reg.tickets.get(tid)
    similar = args.similar if args.similar is not None else (cur[3] if cur else "없음")
    if args.state is None:
        if cur is None:
            raise Refused("%s 행이 아직 없음 — --state 발행중 과 함께 기록할 것" % tid)
        reg.tickets[tid] = cur[:3] + [similar]
        return
    nxt = transition(tuple(cur[:3]) if cur else None, args, tracker, kind)
    if nxt is None:
        reg.tickets.pop(tid, None)
        return
    reg.tickets[tid] = list(nxt) + [similar]
    if nxt[0] == "발행됨" and kind == "create":
        argv = e.get("argv") or []
        if flag_values(argv, "--parent") is not None:
            reg.rels[("하위", tid, "베이스")] = "걸림"
        if tracker == "github" and flag_values(argv, "--blocked-by") is not None:
            for p in g.t[tid]["deps"]:
                reg.rels[("선행", tid, p)] = "걸림"


def transition(cur, args, tracker, kind):
    """Next (state, ref, node) of a base or ticket row, or None to drop it."""
    state = args.state
    if state == "발행중":
        if kind != "create":
            raise Refused("발행중 은 생성 항목에만 기록함")
        if cur is not None and cur[0] == "발행됨":
            raise Refused("이미 발행됨 인 행을 발행중 으로 되돌리지 않음")
        return ("발행중", "-", "-")
    if state == "없음":
        if kind != "resolve" or cur is None or cur[0] != "발행중":
            raise Refused("없음 은 발행중 행의 해소 항목에만 기록함")
        return None
    if state == "발행됨":
        if args.ref is None:
            raise Refused("발행됨 에는 --ref 가 필요함")
        node = args.node_id or "-"
        if tracker == "clickup" and node == "-":
            raise Refused("clickup 의 발행됨 에는 --node-id 가 필요함")
        if cur is not None and cur[0] == "발행됨" and (cur[1], cur[2]) != (args.ref, node):
            raise Refused("이미 다른 참조로 발행됨")
        return ("발행됨", args.ref, node)
    raise Refused("알 수 없는 상태 %s" % state)


def cmd_record(args):
    doc = Doc(args.doc)
    try:
        tracker, target = parse_row(args.row)
    except Refused as e:
        sys.stderr.write("base-split.py: 거절 %s\n" % e)
        return 3
    _, g = run_checks(doc)
    if g.cyclic:
        sys.stderr.write("base-split.py: 거절 선행이 순환함\n")
        return 3
    try:
        reg = Registry(doc, tracker, target).load()
        reg.require_doc_match()
        if args.doc_only:
            if tracker != "없음":
                raise Refused("--doc-only 는 트래커=없음 일 때만 씀")
            if args.entry or args.plan or args.state or args.similar:
                raise Refused("--doc-only 는 다른 기록 인자와 함께 쓰지 않음")
            reg.base = ("문서만", "-", "-")
            for tid in g.ids:
                reg.tickets[tid] = ["문서만", "-", "-", "없음"]
            reg.rels = {}
            reg.fill_relations(g, "문서만")
        else:
            if tracker == "없음":
                raise Refused("트래커=없음 에는 --doc-only 만 기록함")
            if not args.entry or not args.plan:
                raise Refused("--entry 와 --plan 이 필요함")
            reg.fill_relations(g, "대기")
            record_entry(args, doc, g, reg, tracker)
    except Refused as e:
        sys.stderr.write("base-split.py: 거절 %s\n" % e)
        return 3
    reg.write(g)
    sys.stdout.buffer.write(("기록 %s\n" % reg.path).encode("utf-8"))
    sys.stdout.flush()
    return 0


# --------------------------------------------------------------------------

def build_parser():
    # Abbreviations are refused, as on the tracker tools: the gate reads the
    # option spellings it can see.
    parser = argparse.ArgumentParser(prog="base-split.py", allow_abbrev=False,
                                     description="Check, plan and record a base design split.")
    sub = parser.add_subparsers(dest="command")
    sub.required = True
    c = sub.add_parser("check", allow_abbrev=False)
    c.add_argument("doc")
    p = sub.add_parser("plan", allow_abbrev=False)
    p.add_argument("doc")
    p.add_argument("--row", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--tracker", choices=("github", "clickup", "없음"))
    p.add_argument("--target")
    r = sub.add_parser("record", allow_abbrev=False)
    r.add_argument("doc")
    r.add_argument("--row", required=True)
    r.add_argument("--doc-only", action="store_true")
    r.add_argument("--entry")
    r.add_argument("--plan")
    r.add_argument("--state", choices=("발행중", "발행됨", "없음"))
    r.add_argument("--ref")
    r.add_argument("--node-id")
    r.add_argument("--similar")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "check":
            return cmd_check(args)
        if args.command == "plan":
            return cmd_plan(args)
        return cmd_record(args)
    except UsageError as e:
        sys.stderr.write("base-split.py: %s\n" % e)
        return 2
    except Exception as e:  # never echo document or registry bytes
        sys.stderr.write("base-split.py: internal error (%s)\n" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
