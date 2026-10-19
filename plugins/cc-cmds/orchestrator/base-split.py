#!/usr/bin/env python3
"""Check a base design document, plan its ticket publication, and record it.

    base-split.py check  DOC [--observed FIELDS --plan FIELDS-PLAN --row ROW]
    base-split.py plan   DOC --row ROW --out DIR [--tracker T] [--target X] [--fields FIELDS]
    base-split.py record DOC --row ROW (--doc-only
                                       | --entry ID --plan FILE [--state S] [--ref R]
                                         [--node-id N] [--similar LIST])

A base design document is the upper design of a piece of work that is cut
into several tickets; its grammar, the predicates below, the issue-body rules
and the registry format are defined once in `skills/_common/base-design.md`.

`check` prints one line `<predicate> <detail>` per violation of D0 (the
discriminator), P1 (graph shape), P2 (edges and contracts), P3 (file
disjointness), P4 (critical path and width) and B1 (issue-body lint). With
`--observed` (a field document re-read after publication), `--plan` (the
`fields-plan.json` a ClickUp plan wrote) and `--row`, it also prints one line
`observed <ticket> <field> <plan> <observed>` per field, parent link or
relation the re-read does not show as planned. It reads only.

For `트래커=clickup`, `plan` needs `--fields`: the document `similar-items.py
clickup --list-fields` wrote, complete (`"kind": "fields"`, not partial). It
decides each new ticket's assignees, priority and dates from that list's
tickets and the row's optional `원 티켓=`, passes them as create arguments,
derives the relations to existing tickets from the origin's dependencies and
the tickets' `외부 선행`/`외부 후행`, and writes `DIR/fields-plan.json`.

`plan` writes each `**발행 본문**` byte for byte to `DIR/body-*.md`, reads it
back, and writes `DIR/plan.jsonl` — one entry per line, in execution order
(base first, then by dependency layer, contract tickets first inside a layer,
then by number). An entry is `create`, `edit` or `relate` with the exact argv
to run, `resolve` (a ticket the registry left in flight, to be settled by an
exact-title read), or `wait` (its argv needs a reference that does not exist
yet). The caller runs the argvs as given, records each result with `record`,
and calls `plan` again until no `wait` is left; it never builds an argv. A row
with `트래커=없음`, a row that disagrees with `--tracker`/`--target`, a
registry recorded against other document bytes, any check violation, or — for
`트래커=clickup` — a ClickUp tool next to this file that is missing or whose
`--help` does not list an option the plan would pass it, makes `plan` refuse
with no write command at all.

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
import fnmatch  # noqa: E402
import os  # noqa: E402
import posixpath  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
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
FILE_LIST_FIELDS = ("소유 파일", "공유 파일")
# `[` is not here: `app/[id]/page.tsx` is a literal path in routing trees, and
# cutting it at `[` would make it overlap everything under `app/`.
GLOB_META = "*?{"
WHOLE_REPO = "./"

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

ROW_RE = re.compile(r"^- `베이스 발행` \| 트래커=(github|clickup|없음) \| 대상=(\S+)(?: \| 원 티켓=(\S*))?$")
TASK_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
EXTERNAL_FIELDS = ("외부 선행", "외부 후행")
REL_KINDS = ("하위", "선행", "외부선행", "외부후행")
REG_HEAD_RE = re.compile(
    r"^<!-- cc-design-base-tickets v1; doc=([^;]+); doc-sha256=([0-9a-f]{64}); "
    r"tracker=(github|clickup|없음); target=([^;]+) -->$")
REG_BASE_RE = re.compile(r"^- `베이스` \| 상태=(발행중|발행됨|문서만) \| 참조=(\S+) \| 노드 id=(\S+)$")
REG_TICKET_RE = re.compile(
    r"^- `티켓` \| id=(T\d+) \| 상태=(발행중|발행됨|문서만) \| 참조=(\S+) \| 노드 id=(\S+) \| 유사 후보=(.+)$")
# An external relation (`외부선행`, `외부후행`) names an existing ticket of the
# list by its tracker id rather than a document ticket.
REG_REL_RE = re.compile(r"^- `관계` \| 종류=(하위|선행|외부선행|외부후행) \| 원=(T\d+) "
                        r"\| 대상=(T\d+|베이스|[A-Za-z0-9_-]+) \| 상태=(대기|걸림|문서만)$")


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


BULLET_RE = re.compile(r"^\s*[-*+]\s")
# A note after a path: a trailing parenthesis (ASCII or full-width) with or
# without a space in front, unless it directly follows `/` (a directory such
# as `app/(auth)` is a path, not a note), or a dash with spaces round it.
NOTE_RE = re.compile(r"(?<!/)[(（][^()（）]*[)）]$|\s[-–—]{1,2}\s")
# Inside one span: a separator followed by any whitespace, or a `;` at all.
SPAN_LIST_RE = re.compile(r"[,;]\s|;")


class Fields(dict):
    """Field values of one block. `bulleted` names the fields whose next
    non-blank line is a bullet, `continued` those whose next non-blank line is
    neither a field nor a bullet (a wrapped line, a numbered list), and `dups`
    the keys whose field line appears more than once. No field reads any of
    those lines, so what they hold would drop out in silence."""

    def __init__(self):
        dict.__init__(self)
        self.bulleted = set()
        self.continued = set()
        self.dups = set()


def parse_block(lines, inside, start, end):
    """Field lines of one `###` block, outside fences, first value wins."""
    fields = Fields()
    for i in range(start, end):
        if inside[i]:
            continue
        m = FIELD_RE.match(lines[i])
        if not m:
            continue
        key, value = m.group(1), (m.group(2) or "")
        if key in fields:
            fields.dups.add(key)
            continue
        if key in FENCED_FIELDS and value == "":
            v = fenced_value(lines, i + 1)
            fields[key] = v
        else:
            fields[key] = value.strip()
        j = i + 1
        while j < end and not inside[j] and not lines[j].strip():
            j += 1
        if j < end and not inside[j] and not FIELD_RE.match(lines[j]):
            if BULLET_RE.match(lines[j]):
                fields.bulleted.add(key)
            else:
                fields.continued.add(key)
    return fields


def list_shape_faults(fields, key):
    """Why a list field is not written on its own line, or [].

    A list value sits on the field line. An empty value, an empty entry (a
    trailing comma is what a wrapped list leaves behind), or a bullet list,
    numbered list or wrapped line under the field line would read as a
    shorter list and drop the entries from every predicate in silence. File
    lists report their empty entries in split_paths.
    """
    faults = []
    value = fields.get(key)
    if value == "":
        faults.append("값이 비어 있음")
    elif (value is not None and key not in FILE_LIST_FIELDS
          and any(not x.strip() for x in value.split(","))):
        faults.append("빈 항목")
    if key in getattr(fields, "bulleted", ()):
        faults.append("값 아래 불릿 목록")
    if key in getattr(fields, "continued", ()):
        faults.append("값 아래 이어지는 줄")
    return faults


def split_list(value):
    if value is None:
        return []
    value = value.strip()
    if value in ("", "없음"):
        return []
    return [x.strip() for x in value.split(",") if x.strip()]


def split_paths(value):
    """(entries, faults) of a file list, split only on commas outside code
    spans and brackets.

    `src/{a,b}.py` and `src/[a,b].py` are one entry each: cutting them at the
    comma would leave two fragments that match no real path. A list that ends
    inside a code span or a bracket, and an entry that is empty, still holds a
    backtick, pads its code span with spaces or climbs out of the repository,
    is a fault rather than an entry: compared as a literal path it would
    overlap nothing, and P3 would pass in silence. Entries come back
    normalised by norm_path.
    """
    if value is None:
        return [], []
    value = value.strip()
    if value in ("", "없음"):
        return [], []
    items, cur = [], []
    code = False
    depth = 0
    for ch in value:
        if ch == "`":
            code = not code
        elif ch in "{[":
            depth += 1
        elif ch in "}]" and depth:
            depth -= 1
        elif ch == "," and not code and depth == 0:
            items.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    items.append("".join(cur))
    faults = []
    if code:
        faults.append("닫히지 않은 코드 스팬")
    if depth:
        faults.append("닫히지 않은 괄호")
    entries = []
    for x in items:
        if not x.strip():
            # What a wrapped list leaves behind: the rest of it is on lines
            # no field reads.
            faults.append("빈 항목")
            continue
        e = strip_code(x)
        if not e.strip() or "`" in e or e != e.strip():
            faults.append("항목 %s" % x.strip())
            continue
        bare = e == x.strip()
        if bare and (";" in e or any(ch.isspace() for ch in e) or NOTE_RE.search(e)):
            # A bare entry with a space or a trailing note is a path plus a
            # note (`src/x.py (신규)`, `src/x.py(신규)`), one with `;` is two
            # paths; a path that holds a space goes in a code span.
            faults.append("항목 %s" % x.strip())
            continue
        if not bare and (SPAN_LIST_RE.search(e) or NOTE_RE.search(e)):
            # One span around a whole list or a path plus its note: read as
            # one literal path it would overlap nothing.
            faults.append("항목 %s" % x.strip())
            continue
        p = norm_path(e)
        if p == ".." or p.startswith("../"):
            faults.append("항목 %s" % x.strip())
        else:
            entries.append(p)
    return entries, faults


def strip_code(item):
    item = item.strip()
    if len(item) >= 2 and item.startswith("`") and item.endswith("`"):
        return item[1:-1]
    return item


def norm_path(path):
    """`./a//b/` → `a/b/`: the spelling differences that name the same file.

    A leading `/` anchors at the repository root as in CODEOWNERS, so
    `/src/a.py` and `//src/a.py` are `src/a.py`. `./`, `.` and `/` name the
    whole repository and normalise to WHOLE_REPO.
    """
    is_dir = path.endswith("/")
    p = posixpath.normpath(path.lstrip("/"))
    if p == ".":
        return WHOLE_REPO
    return p + "/" if is_dir and not p.endswith("/") else p


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
    """(literal prefix, whether the entry names more than one path).

    A glob is cut at its first metacharacter; a directory entry (trailing
    `/`) is its own prefix and stands for everything under it.
    """
    if path == WHOLE_REPO:
        return "", True
    cut = len(path)
    for ch in GLOB_META:
        k = path.find(ch)
        if k != -1 and k < cut:
            cut = k
    if cut == len(path) and path.endswith("/"):
        return path, True
    return path[:cut], cut < len(path)


def class_hit(path, entry):
    """Whether entry, its brackets read as character classes, matches path.

    `[` is a path character, but an entry written as a class (`src/[ab].py`)
    must not pass as a literal that meets nothing: the pair is reported.
    """
    return "[" in entry and fnmatch.fnmatchcase(path, entry)


def paths_overlap(a, b):
    pa, ga = glob_prefix(a)
    pb, gb = glob_prefix(b)
    if not ga and not gb:
        return a == b or class_hit(a, b) or class_hit(b, a)
    return pa.startswith(pb) or pb.startswith(pa)


def whole_repo_share(s):
    """Whether shared entry s covers any path of the repository, whatever its
    spelling: it covers a root file or a nested path made only of a letter s
    never spells. `*`, `**`, `**/*` and `?*` do; `*.lock`, `**/*.py` and
    `src/**` fix a name and do not.
    """
    if s == WHOLE_REPO:
        return True
    c = next(ch for ch in map(chr, range(0x61, 0x110000)) if ch.isalnum() and ch not in s)
    n = c * 8
    probes = (n, n + "." + n, n + "/" + n, n + "/" + n + "." + n)
    return any(covered_by(x, s) for x in probes)


def covered_by(p, s):
    """Whether shared entry s certainly contains every path owned entry p names.

    A glob is matched with fnmatch, where `*` and `?` also match `/`.
    """
    if p == s:
        return True
    ps, gp = glob_prefix(p)
    if s.endswith("/") and glob_prefix(s)[0] == s:
        return ps.startswith(s)
    if not gp and glob_prefix(s)[1] and "{" not in s:
        # `[` is literal in an entry, so it must not open a class in fnmatch.
        return fnmatch.fnmatchcase(p, s.replace("[", "[[]"))
    return False


def file_overlaps(t1, t2):
    """(repo, path) pairs of t1 and t2 that overlap, both shared lists removed."""
    if t1["repo"] != t2["repo"]:
        return []
    shared = list(t1["shared"]) + list(t2["shared"])
    a = [p for p in t1["owned"] if not any(covered_by(p, s) for s in shared)]
    b = [p for p in t2["owned"] if not any(covered_by(p, s) for s in shared)]
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

    def add_dups(self, where, fields):
        # The first value wins, so a second field line of the same key is
        # read by nothing.
        for key in sorted(getattr(fields, "dups", ())):
            self.add("P1", "%s 필드 중복 %s" % (where, key))

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
            self.add_dups(tid, f)
            self.ids.append(tid)
            for key in ("선행", "제공 계약", "소비 계약"):
                faults = list_shape_faults(f, key)
                if faults:
                    self.add("P1", "%s %s 목록 형식 오류 %s" % (tid, key, "; ".join(faults)))
            external = {}
            for key in EXTERNAL_FIELDS:
                # Optional: existing tracker tickets outside the split.
                faults = list_shape_faults(f, key) if f.get(key) is not None else []
                ids = split_list(f.get(key))
                faults += ["항목 %s" % x for x in ids if not TASK_ID_RE.match(strip_code(x))]
                if faults:
                    self.add("P1", "%s %s 목록 형식 오류 %s" % (tid, key, "; ".join(faults)))
                external[key] = sorted(set(strip_code(x) for x in ids if TASK_ID_RE.match(strip_code(x))))
            files = {}
            for key in ("소유 파일", "공유 파일"):
                shape = list_shape_faults(f, key)
                entries, faults = split_paths(f.get(key))
                whole = [x for x in entries if whole_repo_share(x)] if key == "공유 파일" else []
                if whole:
                    # Shared lists exempt both tickets of a pair, so a shared
                    # whole repository would switch P3 off for every pair.
                    entries = [x for x in entries if x not in whole]
                    faults.append("레포 전체 공유 항목 %s" % ", ".join(whole))
                if key == "소유 파일" and f.get(key) is not None and not shape:
                    # A ticket that owns nothing is skipped by P3, so an empty
                    # owned list would hide the overlap it was meant to show.
                    if f.get(key).strip() == "없음":
                        faults.append("없음 (소유 파일은 비어 있을 수 없음)")
                    elif not entries and not faults:
                        faults.append("비어 있음")
                faults = shape + faults
                files[key] = entries
                if faults:
                    self.add("P1", "%s %s 목록 형식 오류 %s" % (tid, key, "; ".join(faults)))
            raw_repo = f.get("레포")
            repo = strip_code(raw_repo or "").strip()
            if raw_repo is not None and not REPO_RE.match(repo):
                self.add("P1", "%s 레포 값 형식 오류 %s" % (tid, raw_repo.strip() or "(빈 값)"))
            self.t[tid] = {
                "num": num, "title": title, "kind": f.get("종류") or "",
                # Compared without its code span and case-folded: `o/r`, `O/R`
                # and a span around either are one repository to P3.
                "repo": repo.lower(),
                "deps": split_list(f.get("선행")),
                "provides": split_list(f.get("제공 계약")),
                "consumes": split_list(f.get("소비 계약")),
                "owned": files["소유 파일"],
                "shared": files["공유 파일"],
                "nesting": bool((f.get("중첩 사유") or "").strip()),
                "pub_title": f.get("발행 제목"), "body": f.get("발행 본문"),
                "ext_pred": external["외부 선행"], "ext_succ": external["외부 후행"],
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
            self.add_dups(cid, f)
            for key in ("제공 티켓", "소비 티켓"):
                faults = list_shape_faults(f, key)
                if faults:
                    self.add("P1", "%s %s 목록 형식 오류 %s" % (cid, key, "; ".join(faults)))
            self.c[cid] = {"providers": split_list(f.get("제공 티켓")),
                           "consumers": split_list(f.get("소비 티켓"))}
        if doc.base is None:
            self.add("P1", "베이스 티켓 블록 없음")
        else:
            for key in ("발행 제목", "발행 본문"):
                if doc.base.get(key) is None:
                    self.add("P1", "베이스 티켓 필드 없음 %s" % key)
            self.add_dups("베이스 티켓", doc.base)
        self.add_dups("티켓 분할", doc.header)

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
        # A consumer named only on the contract side consumes it all the same:
        # P2 must check that ticket's reach to the provider too.
        for cid in sorted(self.c, key=lambda x: int(x[1:])):
            for tid in self.c[cid]["consumers"]:
                if cid not in self.t[tid]["consumes"]:
                    self.t[tid]["consumes"].append(cid)

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
    """(tracker, target, origin) of a `베이스 발행` row; origin is the
    optional `원 티켓=` id, or None."""
    m = ROW_RE.match(row.strip())
    if not m:
        raise Refused("베이스 발행 행을 읽지 못함")
    tracker, target, origin = m.group(1), m.group(2), m.group(3)
    if tracker == "없음" and target != "-":
        raise Refused("트래커=없음 인데 대상이 - 가 아님")
    if tracker == "github" and not REPO_RE.match(target):
        raise Refused("github 대상이 owner/name 꼴이 아님")
    if tracker != "없음" and target == "-":
        raise Refused("트래커가 있는데 대상이 -")
    if origin is not None:
        if tracker != "clickup":
            raise Refused("원 티켓 은 clickup 행에만 둡니다")
        if not TASK_ID_RE.match(origin):
            raise Refused("원 티켓 값 형식 오류")
    return tracker, target, origin


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
                internal = re.match(r"^(T\d+|베이스)$", r.group(3)) is not None
                if internal != (r.group(1) in ("하위", "선행")):
                    raise Refused("등록부에 읽을 수 없는 줄이 있음")
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
        # The external relations the document names are filled here; those a
        # plan derives from the origin ticket are added when they are recorded.
        for tid in g.ids:
            self.rels.setdefault(("하위", tid, "베이스"), default)
            for p in g.t[tid]["deps"]:
                self.rels.setdefault(("선행", tid, p), default)
            for x in g.t[tid]["ext_pred"]:
                self.rels.setdefault(("외부선행", tid, x), default)
            for x in g.t[tid]["ext_succ"]:
                self.rels.setdefault(("외부후행", tid, x), default)

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
    if dst == "베이스":
        target = (0, -1, "")
    elif kind in ("하위", "선행"):
        target = (1, int(dst[1:]), "")
    else:
        target = (2, 0, dst)
    return (REL_KINDS.index(kind), int(src[1:]), target)


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


# --------------------------------------------------------------------------
# ClickUp fields and external relations
# --------------------------------------------------------------------------

FIELD_NAMES = ("assignees", "priority", "start_date", "due_date")
FIELD_LIMIT_REASON = "limit"


def load_fields_doc(path):
    """The field document `similar-items.py clickup --list-fields` wrote."""
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise UsageError("cannot read %s (%s)" % (path, type(e).__name__))
    if not isinstance(data, dict) or data.get("kind") != "fields":
        raise Refused("필드 문서가 아님 (\"kind\": \"fields\" 없음)")
    if data.get("partial") is not False:
        if data.get("reason") == FIELD_LIMIT_REASON:
            raise Refused("필드 문서가 부분 조회 (limit) — 목록이 2000개를 넘어 이 경로로 발행할 수 없음")
        raise Refused("필드 문서가 부분 조회 (%s)" % data.get("reason"))
    for key in ("tasks", "task_fields"):
        if not isinstance(data.get(key), list) or not all(
                isinstance(r, dict) and isinstance(r.get("id"), str) for r in data[key]):
            raise Refused("필드 문서의 %s 를 읽지 못함" % key)
    return data


def snapshot_of(fdoc):
    """Every ticket the document read, the one-by-one reads winning."""
    snap = {}
    for r in fdoc["tasks"] + fdoc["task_fields"]:
        snap[r["id"]] = r
    return snap


def ms_of(rec, key):
    v = rec.get(key) if rec else None
    return v if isinstance(v, str) and v.isdigit() else None


def is_set(rec, name):
    if name == "assignees":
        return bool(rec.get("assignees"))
    if name == "priority":
        return rec.get("priority") is not None
    return ms_of(rec, name) is not None


def origin_edges(fdoc, origin):
    """(tickets the origin waited on, tickets that waited on the origin)."""
    rec = next((r for r in fdoc["task_fields"] if r["id"] == origin), None)
    if rec is None:
        raise Refused("원 티켓 %s 이 필드 문서의 task_fields 에 없음" % origin)
    waits_on, waiters = set(), set()
    for d in rec.get("dependencies") or []:
        if not isinstance(d, dict):
            continue
        if d.get("task_id") == origin and d.get("depends_on"):
            waits_on.add(str(d["depends_on"]))
        elif d.get("depends_on") == origin and d.get("task_id"):
            waiters.add(str(d["task_id"]))
    return waits_on, waiters


def external_edges(g, fdoc, origin):
    """{ticket: (preds, succs)} of existing tickets outside the split.

    The origin's waits-on become predecessors of every root ticket (no
    predecessor inside the split), its waiters successors of every leaf ticket
    (no successor inside the split); a ticket's `외부 선행`/`외부 후행` add to
    those. Every id must be in the snapshot.
    """
    waits_on, waiters = origin_edges(fdoc, origin) if origin else (set(), set())
    has_succ = set(p for t in g.ids for p in g.t[t]["deps"])
    snap = snapshot_of(fdoc)
    edges = {}
    for tid in g.ids:
        preds = set(g.t[tid]["ext_pred"]) | (waits_on if not g.t[tid]["deps"] else set())
        succs = set(g.t[tid]["ext_succ"]) | (waiters if tid not in has_succ else set())
        for x in sorted(preds | succs):
            if x not in snap:
                raise Refused("스냅숏에 없는 티켓 id %s (%s)" % (x, tid))
        edges[tid] = (sorted(preds), sorted(succs))
    return edges


def decide_fields(g, fdoc, origin, run_nodes, edges):
    """The fields of every new ticket, keyed `베이스` and the ticket ids.

    A field is in use when more than half of the denominator - the list's open
    top-level tickets other than the origin and this split's own tickets - set
    it; exactly half, or an empty denominator, leaves it empty. Values come
    from reference tickets: the origin's assignees, else the assignees every
    tag-sharing denominator ticket has in common; the latest due date of the
    ticket's existing predecessors as its start and the earliest start of its
    existing successors as its due date, else the origin's; the origin's
    priority, else the denominator's single most common one. A `*_date_time`
    flag is copied only when the reference ticket's record carries the key.
    """
    snap = snapshot_of(fdoc)
    o = snap.get(origin) if origin else None
    denom = [r for r in fdoc["tasks"]
             if not r.get("parent") and r["id"] != origin and r["id"] not in run_nodes]
    used = dict((n, bool(denom) and 2 * sum(1 for r in denom if is_set(r, n)) > len(denom))
                for n in FIELD_NAMES)

    assignees = None
    if o is not None and o.get("assignees"):
        assignees = sorted(set(o["assignees"]))
    elif o is not None:
        tags = set(o.get("tags") or [])
        sharing = [r for r in denom if tags & set(r.get("tags") or [])]
        if sharing:
            common = set(sharing[0].get("assignees") or [])
            for r in sharing[1:]:
                common &= set(r.get("assignees") or [])
            assignees = sorted(common) or None
    priority = o.get("priority") if o is not None else None
    if priority is None:
        counts = {}
        for r in denom:
            if r.get("priority") is not None:
                counts[r["priority"]] = counts.get(r["priority"], 0) + 1
        if counts:
            top = max(counts.values())
            best = [p for p, n in counts.items() if n == top]
            priority = best[0] if len(best) == 1 else None

    def date(preds_or_succs, key, pick, own_key):
        cands = [(int(ms_of(snap[x], key)), x) for x in preds_or_succs if ms_of(snap.get(x), key)]
        if cands:
            ref = snap[pick(cands)[1]]
            return ms_of(ref, key), ref, key + "_time"
        if ms_of(o, own_key):
            return ms_of(o, own_key), o, own_key + "_time"
        return None, None, None

    plan = {}
    keys = ["베이스"] + list(g.ids)
    for key in keys:
        preds, succs = edges.get(key, ([], []))
        values = {"assignees": assignees, "priority": priority}
        refs = {}
        values["start_date"], sref, sflag = date(preds, "due_date", max, "start_date")
        values["due_date"], dref, dflag = date(succs, "start_date", min, "due_date")
        refs["start_date"], refs["due_date"] = (sref, sflag), (dref, dflag)
        decided, empty, flags = {}, {}, {}
        for n in FIELD_NAMES:
            if not used[n]:
                empty[n] = "리스트가 쓰지 않음"
            elif values[n] is None:
                empty[n] = "참조 값 없음"
            else:
                decided[n] = values[n]
        copied = []
        for n in ("start_date", "due_date"):
            if n not in decided:
                continue
            ref, flag = refs[n]
            copied.append(flag in ref)
            if flag in ref:
                flags[n + "_time"] = bool(ref[flag])
        fmt = "복사" if copied and all(copied) else "미상(생략)"
        plan[key] = {"fields": decided, "empty": empty, "date_flags": flags, "date_format": fmt,
                     "external_pred": preds, "external_succ": succs}
    return plan


def field_argv(decision):
    if decision is None:
        return []
    f, flags = decision["fields"], decision["date_flags"]
    argv = []
    for a in f.get("assignees") or []:
        argv += ["--assignee", str(a)]
    if "priority" in f:
        argv += ["--priority", str(f["priority"])]
    if "start_date" in f:
        argv += ["--start-date", f["start_date"]]
        if flags.get("start_date_time"):
            argv.append("--start-date-time")
    if "due_date" in f:
        argv += ["--due-date", f["due_date"]]
        if flags.get("due_date_time"):
            argv.append("--due-date-time")
    return argv


def field_entry(e, decision):
    if decision is not None:
        e["fields"] = {"values": decision["fields"], "empty": decision["empty"]}
        e["date_format"] = decision["date_format"]
    return e


def build_plan(doc, g, reg, out, tracker, target, fplan=None):
    fplan = fplan or {}
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

    def external_rels(tid):
        d = fplan.get(tid)
        if d is None:
            return []
        return ([("외부선행", x) for x in d["external_pred"]]
                + [("외부후행", x) for x in d["external_succ"]])

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
                    "--description-file", base_body] + field_argv(fplan.get("베이스"))
        entries.append(field_entry(entry("base", "create", "베이스", argv, title=base_title),
                                   fplan.get("베이스")))
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
                        "--description-file", body, "--parent", base_node] + field_argv(fplan.get(tid))
            entries.append(field_entry(entry(tid, "create", tid, argv, title=t["pub_title"]), fplan.get(tid)))
            continue

    # Relations that a creation did not carry: GitHub fills them by edit on a
    # resume, ClickUp makes every dependency with its own call.
    for tid in sorted(g.ids, key=lambda u: g.t[u]["num"]):
        ext = external_rels(tid)
        if not issued(ticket_state(tid)):
            if tracker == "clickup":
                for p in g.t[tid]["deps"]:
                    eid = "rel:선행:%s:%s" % (tid, p)
                    entries.append(entry(eid, "wait", "관계 선행 %s %s" % (tid, p), why="참조 없음 %s" % tid))
                for kind, x in ext:
                    eid = "rel:%s:%s:%s" % (kind, tid, x)
                    entries.append(entry(eid, "wait", "관계 %s %s %s" % (kind, tid, x), why="참조 없음 %s" % tid))
            continue
        for kind, x in ext:
            if reg.rels.get((kind, tid, x), "대기") != "대기" or node_of(tid) is None:
                continue
            # An external predecessor is waited on by the new ticket; an external
            # successor waits on it, so the same tool takes the arguments swapped.
            pair = ["--task", node_of(tid), "--depends-on", x] if kind == "외부선행" \
                else ["--task", x, "--depends-on", node_of(tid)]
            entries.append(entry("rel:%s:%s:%s" % (kind, tid, x), "relate", "관계 %s %s %s" % (kind, tid, x),
                                 [relate_tool] + pair))
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


CLICKUP_TOOLS = (("clickup-create.py", ("--list", "--name", "--description-file", "--parent",
                                        "--assignee", "--priority", "--start-date", "--start-date-time",
                                        "--due-date", "--due-date-time")),
                 ("clickup-relate.py", ("--task", "--depends-on")))


def clickup_tools_unready(here):
    """Why the ClickUp argvs this plan would emit cannot run here, or None.

    Each tool must be an executable next to this file whose own parser lists
    every option the plan passes it. Asking `--help` reads the parser without
    reaching the tracker; a plan whose base creation succeeds and whose first
    child creation then dies on an unknown option leaves an orphan behind.
    """
    for name, flags in CLICKUP_TOOLS:
        path = os.path.join(here, name)
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            return "%s 가 실행 가능한 파일로 없음" % name
        try:
            r = subprocess.run([path, "--help"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        except (OSError, subprocess.SubprocessError) as e:
            return "%s --help 를 읽지 못함 (%s)" % (name, type(e).__name__)
        text = r.stdout.decode("utf-8", "replace")
        if r.returncode != 0:
            return "%s --help 가 %d 로 끝남" % (name, r.returncode)
        missing = [f for f in flags
                   if not re.search(r"(?<![A-Za-z0-9-])%s(?![A-Za-z0-9-])" % re.escape(f), text)]
        if missing:
            return "%s 가 %s 를 받지 않음" % (name, ", ".join(missing))
    return None


def cmd_check(args):
    given = [x is not None for x in (args.observed, args.plan, args.row)]
    if any(given) and not all(given):
        raise UsageError("--observed, --plan and --row go together")
    doc = Doc(args.doc)
    violations, g = run_checks(doc)
    lines = ["%s %s" % (pred, detail) for pred, detail in violations]
    if args.observed is not None:
        lines += observed_mismatches(doc, g, args)
    for line in lines:
        sys.stdout.buffer.write((line + "\n").encode("utf-8"))
    sys.stdout.flush()
    return 1 if lines else 0


def shown(value):
    if value is None or value == []:
        return "-"
    if isinstance(value, list):
        return ",".join(str(x) for x in value)
    return str(value)


def observed_mismatches(doc, g, args):
    """`observed <ticket> <field> <plan> <observed>` for every way the
    re-read tickets differ from the fields plan and the split's relations.

    Dates are compared as millisecond values only, whatever their flags.
    """
    try:
        tracker, target, _ = parse_row(args.row)
        if tracker != "clickup":
            raise Refused("--observed 는 트래커=clickup 행에만 씀")
        reg = Registry(doc, tracker, target).load()
        obs = load_fields_doc(args.observed)
    except Refused as e:
        return ["observed - 입력 - %s" % str(e).replace(" ", "_")]
    try:
        with open(args.plan, "rb") as f:
            fplan = json.loads(f.read().decode("utf-8"))
        tickets = fplan["tickets"]
    except (OSError, UnicodeDecodeError, ValueError, KeyError, TypeError) as e:
        raise UsageError("cannot read %s (%s)" % (args.plan, type(e).__name__))
    snap = snapshot_of(obs)
    pairs = set()
    for r in snap.values():
        for d in r.get("dependencies") or []:
            pairs.add((d.get("task_id"), d.get("depends_on")))

    def node(key):
        s = reg.base if key == "베이스" else (reg.tickets.get(key) or [None] * 3)
        return s[2] if s and s[0] == "발행됨" and s[2] != "-" else None

    out = []
    base_node = node("베이스")
    for key in ["베이스"] + [t for t in g.ids if t in tickets]:
        d = tickets.get(key)
        if d is None:
            continue
        n = node(key)
        rec = snap.get(n) if n else None
        if rec is None:
            out.append("observed %s 조회 %s -" % (key, n or "-"))
            continue
        want = d.get("fields") or {}
        checks = (
            ("assignees", sorted(want.get("assignees") or []), sorted(rec.get("assignees") or [])),
            ("priority", want.get("priority"), rec.get("priority")),
            ("start_date", want.get("start_date"), ms_of(rec, "start_date")),
            ("due_date", want.get("due_date"), ms_of(rec, "due_date")),
        )
        for name, plan_v, obs_v in checks:
            if name in ("start_date", "due_date"):
                same = (None if plan_v is None else int(plan_v)) == (None if obs_v is None else int(obs_v))
            else:
                same = plan_v == obs_v
            if not same:
                out.append("observed %s %s %s %s" % (key, name, shown(plan_v), shown(obs_v)))
        if key == "베이스":
            continue
        if rec.get("parent") != base_node:
            out.append("observed %s 하위 %s %s" % (key, shown(base_node), shown(rec.get("parent"))))
        for p in g.t[key]["deps"]:
            if (n, node(p)) not in pairs:
                out.append("observed %s 선행 %s 없음" % (key, shown(node(p))))
        for x in d.get("external_pred") or []:
            if (n, x) not in pairs:
                out.append("observed %s 외부선행 %s 없음" % (key, x))
        for x in d.get("external_succ") or []:
            if (x, n) not in pairs:
                out.append("observed %s 외부후행 %s 없음" % (key, x))
    return out


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
        tracker, target, origin = parse_row(args.row)
    except Refused as e:
        return refuse_plan(out, str(e))
    if args.tracker is not None and args.tracker != tracker:
        return refuse_plan(out, "--tracker %s 가 행의 트래커 %s 와 다름" % (args.tracker, tracker))
    if args.target is not None and args.target != target:
        return refuse_plan(out, "--target 이 행의 대상과 다름")
    if tracker == "없음":
        return refuse_plan(out, "트래커=없음 — 쓰기 명령을 내지 않음 (record --doc-only)")
    if tracker == "clickup":
        why = clickup_tools_unready(os.path.dirname(os.path.realpath(__file__)))
        if why:
            return refuse_plan(out, "ClickUp 도구 미비 — %s" % why)
        if args.fields is None:
            return refuse_plan(out, "트래커=clickup 에는 --fields <필드 문서> 가 필요함")
    elif args.fields is not None:
        return refuse_plan(out, "--fields 는 트래커=clickup 행에만 씀")
    violations, g = run_checks(doc)
    if violations:
        return refuse_plan(out, "점검 위반 %d건 — check 로 확인" % len(violations))
    try:
        reg = Registry(doc, tracker, target).load()
        reg.require_doc_match()
        fplan = None
        if tracker == "clickup":
            fdoc = load_fields_doc(args.fields)
            if str(fdoc.get("list")) != target:
                raise Refused("필드 문서의 목록이 행의 대상과 다름")
            run_nodes = set(s[2] for s in reg.tickets.values() if s[2] != "-")
            if reg.base is not None and reg.base[2] != "-":
                run_nodes.add(reg.base[2])
            fplan = decide_fields(g, fdoc, origin, run_nodes, external_edges(g, fdoc, origin))
        elif any(g.t[t]["ext_pred"] or g.t[t]["ext_succ"] for t in g.ids):
            raise Refused("외부 선행·외부 후행 은 트래커=clickup 발행에서만 건다")
    except Refused as e:
        return refuse_plan(out, str(e))
    entries = build_plan(doc, g, reg, out, tracker, target, fplan)
    data = "".join(json.dumps(e, ensure_ascii=False, sort_keys=True) + "\n" for e in entries)
    if fplan is not None:
        doc_plan = {"list": target, "origin": origin, "tickets": fplan}
        write_atomic(os.path.join(out, "fields-plan.json"),
                     (json.dumps(doc_plan, ensure_ascii=False, sort_keys=True, indent=1) + "\n").encode("utf-8"))
    write_atomic(os.path.join(out, "plan.jsonl"), data.encode("utf-8"))
    lines = []
    for e in entries:
        argv = " ".join(shlex.quote(a) for a in e["argv"]) if e["argv"] else "-"
        lines.append("%s\t%s\t%s\t%s\n" % (e["entry"], e["kind"], e["row"], argv))
    if not entries:
        left = sum(1 for s in reg.rels.values() if s == "대기")
        if left:
            lines.append("계획 항목 없음 — 대기 관계 %d건은 이 트래커 도구로 걸 수 없음\n" % left)
        else:
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
        external = parts[1] in ("외부선행", "외부후행")
        if external and (kind != "relate" or parts[2] not in g.t or not TASK_ID_RE.match(parts[3])):
            raise Refused("외부 관계 %s 를 기록할 수 없음" % row)
        if key not in reg.rels and not external:
            # An external relation the plan derived from the origin ticket is
            # not in the document, so its first record adds it.
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
    # A ClickUp ticket is only ever created with `--parent` (the plan waits until
    # the base has a node), so the ticket a resolve adopts is already a subtask
    # of the base. The plan has no ClickUp entry that sets a parent afterwards,
    # so without this the relation stays `대기` and the split never completes.
    if nxt[0] == "발행됨" and kind == "resolve" and tracker == "clickup":
        reg.rels[("하위", tid, "베이스")] = "걸림"


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
        tracker, target, _ = parse_row(args.row)
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
    c.add_argument("--observed")
    c.add_argument("--plan")
    c.add_argument("--row")
    p = sub.add_parser("plan", allow_abbrev=False)
    p.add_argument("doc")
    p.add_argument("--row", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--tracker", choices=("github", "clickup", "없음"))
    p.add_argument("--target")
    p.add_argument("--fields")
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
