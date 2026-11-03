#!/usr/bin/env python3
"""Check a base design document, plan its ticket publication, and record it.

    base-split.py check  DOC [--observed FIELDS --plan FIELDS-PLAN --row ROW]
    base-split.py plan   DOC --row ROW --out DIR [--tracker T] [--target X] [--fields FIELDS]
    base-split.py record DOC --row ROW (--doc-only
                                       | --entry ID --plan FILE [--state S] [--ref R]
                                         [--node-id N] [--similar LIST])
    base-split.py record --started DOC --ticket T<n> --run RUN
    base-split.py child-doc DOC --ticket T<n> --cutpoint C --out PATH
    base-split.py fence-check CHILD
    base-split.py revise DOC --from OLD --to NEW --ticket T<n> --run RUN

A base design document is the upper design of a piece of work that is cut
into several tickets; its grammar, the predicates below, the issue-body rules
and the registry format are defined once in `skills/_common/base-design.md`.
A ticket delivery design (`**문서 종류**: 티켓 배달 설계`) is a complete
design whose slicing is a ticket split in the same grammar; what it adds is
defined in `skills/_common/ticket-delivery.md`. The discriminator line picks
the kind, and `check` runs T0–T5 on top of the checks below for that kind.

`record --started` adds the `착수` row of a child run to the registry of a
ticket delivery design, under the `<doc file name>.revise.lock` lock, keeping
the document sha256 the registry head carries. `child-doc` writes the frozen
child document of a ticket whose child design is skipped, only when it passes
`fence-check`. `fence-check` reads a child document and prints one `F1`
line per declared slice file outside the ticket's owned and shared files and
not listed with a reason under `**티켓 밖 파일**`. `revise` replaces the
upper document with a candidate after checking that the change stays inside
what the child run of that ticket may change, then rewrites the registry
head sha256, all under the same lock.

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
the tickets' `외부 선행`/`외부 후행`, and writes `DIR/fields-plan.json`. An
existing ticket the document shows in another list is left out of the
relations and named under the ticket's `external_skipped`; an id the document
does not carry at all is refused.

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
import time  # noqa: E402

KIND_LINE = "**문서 종류**: 베이스 설계"
TICKETS_KIND_LINE = "**문서 종류**: 티켓 배달 설계"
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
# A child run of a ticket delivery design that started on ticket T<n>; the
# rows of one ticket from different runs all stay.
REG_STARTED_RE = re.compile(r"^- `착수` \| id=(T\d+) \| 런=([A-Za-z0-9_.-]+)$")


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
    def __init__(self, path, raw=None):
        self.path = path
        if raw is None:
            try:
                with open(path, "rb") as f:
                    raw = f.read()
            except OSError as e:
                raise UsageError("cannot read %s (%s)" % (path, type(e).__name__))
        self.raw = raw
        try:
            text = self.raw.decode("utf-8")
        except UnicodeDecodeError:
            raise UsageError("%s is not UTF-8" % path)
        self.sha256 = hashlib.sha256(self.raw).hexdigest()
        self.lines = split_lines(text)
        self.inside = mark_fences(self.lines)
        self.kind_line = False
        self.tickets_kind_line = False
        self.heads = []        # [(index, level, text)] of `##`/`###` lines outside fences
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
            if line == TICKETS_KIND_LINE:
                self.tickets_kind_line = True
            if line.startswith("## ") or line.startswith("### "):
                level = 2 if line.startswith("## ") else 3
                heads.append((i, level, line))
                if line == SPLIT_HEADING:
                    self.split_heading = True
                if line == SLICING_HEADING:
                    self.slicing_heading = True
        self.heads = heads
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

    @property
    def kind(self):
        """`base`, `tickets`, or None when the document carries no single
        discriminator line (D0 reports both cases)."""
        if self.kind_line == self.tickets_kind_line:
            return None
        return "base" if self.kind_line else "tickets"

    def h2_sections(self):
        """[(heading, start, end)]: each `## ` heading line and the index of
        the next `## ` heading (or the end of the document)."""
        h2 = [(i, text) for i, level, text in self.heads if level == 2]
        out = []
        for k, (i, text) in enumerate(h2):
            end = h2[k + 1][0] if k + 1 < len(h2) else len(self.lines)
            out.append((text, i, end))
        return out

    def section(self, heading):
        """(start, end) of the first `## ` section with this exact heading."""
        for text, i, end in self.h2_sections():
            if text == heading:
                return i, end
        return None

    def h3_blocks(self, start, end):
        """[(heading, i, j)] of the `### ` blocks between start and end; j is
        the next `##`/`###` heading or end."""
        inner = [(i, level, text) for i, level, text in self.heads if start <= i < end]
        out = []
        for k, (i, level, text) in enumerate(inner):
            if level != 3:
                continue
            j = inner[k + 1][0] if k + 1 < len(inner) else end
            out.append((text, i, j))
        return out

    def block_lines(self, i, j):
        """Lines i..j with the trailing blank lines dropped."""
        seg = list(self.lines[i:j])
        while seg and not seg[-1].strip():
            seg.pop()
        return seg


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
    if not doc.kind_line and not doc.tickets_kind_line:
        out.append(("D0", "판별자 줄 없음 %s 또는 %s" % (KIND_LINE, TICKETS_KIND_LINE)))
    elif doc.kind_line and doc.tickets_kind_line:
        out.append(("D0", "판별자 줄 둘 %s 와 %s" % (KIND_LINE, TICKETS_KIND_LINE)))
    if not doc.split_heading:
        out.append(("D0", "표제 없음 %s" % SPLIT_HEADING))
    if doc.slicing_heading:
        what = "티켓 배달 설계 문서" if doc.kind == "tickets" else "베이스 문서"
        out.append(("D0", "%s에 %s 가 있음" % (what, SLICING_HEADING)))
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
    if doc.kind == "tickets":
        v.extend(check_tickets_kind(doc, g))
    seen = set()
    uniq = []
    for item in v:
        if item not in seen:
            seen.add(item)
            uniq.append(item)
    return uniq, g


# --------------------------------------------------------------------------
# Ticket delivery documents — `skills/_common/ticket-delivery.md`
# --------------------------------------------------------------------------

ARCH_HEADING = "## 합의된 아키텍처"
DECISIONS_HEADING = "## 주요 결정사항과 근거"
RESIDUAL_HEADING = "## 구현 시 검증 항목"
HISTORY_HEADING = "## 개정 이력"
UNRESOLVED_RE = re.compile(r"^## .*미해결\s+이슈")
R_HEAD_RE = re.compile(r"^### R(\d+)\. (.+)$")
TD_FIELDS = ("설계 절", "하위 설계", "잔여 항목", "미해결 항목")
TD_LIST_FIELDS = ("설계 절", "잔여 항목", "미해결 항목")
SUB_DESIGN_VALUES = ("생략 가능", "필요")
SKIPPABLE_MAX_FILES = 20
CUTPOINTS = ("커밋", "브랜치", "push", "PR", "머지", "배포", "머지후착수")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
STATE_LINE_RE = re.compile(r"^\s*(?:[-*]\s+)?(?:\*\*상태\*\*:|\*\*상태:|상태:)\s*(.*)$")
STATE_CLOSED_RE = re.compile(r"^해결(?:됨)?(?:\s*[—·(].*)?$")
LINKAGE_SENTENCE = ("이 문서의 `## 베이스 제약` 절에 옮긴 티켓 블록과 계약 블록은 "
                    "이 절의 결정과 똑같이 구현을 구속한다.")
CHILD_SENTENCE = "이 문서의 설계는 `## 베이스 제약` 에 옮긴 상위 티켓 부분이 전부다."
DECISIONS_COPY_HEADING = "### 상위 문서의 주요 결정사항과 근거"


def parse_quoted(value):
    """(items, fault) of a `「### …」` list: one item per pair, only commas
    and blanks between pairs, each item a `### ` heading compared by the text
    after `### `. `없음` is the empty list."""
    if value is None:
        return [], "필드 없음"
    value = value.strip()
    if value == "없음":
        return [], None
    if value == "":
        return [], "값이 비어 있음"
    items = []
    pos = 0
    while pos < len(value):
        ch = value[pos]
        if ch in ", \t":
            pos += 1
            continue
        if ch != "「":
            return items, "쌍 밖의 글 %s" % value[pos:pos + 12]
        close = value.find("」", pos + 1)
        if close == -1:
            return items, "닫히지 않은 「"
        inner = value[pos + 1:close]
        if not inner.startswith("### ") or not inner[4:].strip():
            return items, "항목이 ### 표제가 아님 「%s」" % inner
        if inner[4:] in items:
            return items, "같은 항목 두 번 「%s」" % inner
        items.append(inner[4:])
        pos = close + 1
    if not items:
        return items, "값이 비어 있음"
    return items, None


def quoted_list(items):
    return ", ".join("「### %s」" % x for x in items) if items else "없음"


def heading_titles(doc):
    """The texts of every `##`/`###` heading, without the `#` prefix."""
    return [text.split(" ", 1)[1] for _, _, text in doc.heads]


def longest_heading(rest, titles):
    best = None
    for t in titles:
        if rest.startswith(t) and (best is None or len(t) > len(best)):
            best = t
    return best


def arch_subsections(doc):
    """[(title, i, j)] of the `###` blocks of `## 합의된 아키텍처`."""
    sec = doc.section(ARCH_HEADING)
    if sec is None:
        return []
    return [(t[4:], i, j) for t, i, j in doc.h3_blocks(*sec)]


def residual_items(doc):
    """[(title, number, i, j)] of the `### R<n>. …` blocks."""
    sec = doc.section(RESIDUAL_HEADING)
    if sec is None:
        return []
    out = []
    for t, i, j in doc.h3_blocks(*sec):
        m = R_HEAD_RE.match(t)
        if m:
            out.append((t[4:], int(m.group(1)), i, j))
    return out


def unresolved_section(doc):
    found = None
    for text, i, end in doc.h2_sections():
        if UNRESOLVED_RE.match(text):
            found = (i, end)
    return found


def open_entries(doc):
    """([(title, i, j)] of the open `###` entries, [table rows that are open])
    of the last `## …미해결 이슈…` section, read as `unresolved-closure.md`
    reads it: an entry is closed when its first `상태` value is `해결` or
    `해결됨`, alone or followed by `—`, `·` or `(`."""
    sec = unresolved_section(doc)
    if sec is None:
        return [], []
    start, end = sec
    blocks = doc.h3_blocks(start, end)
    entries = []
    for t, i, j in blocks:
        state = None
        for k in range(i + 1, j):
            if doc.inside[k]:
                continue
            m = STATE_LINE_RE.match(doc.lines[k])
            if m:
                state = m.group(1).replace("**", "").strip()
                break
        if state is None or not STATE_CLOSED_RE.match(state):
            entries.append((t[4:], i, j))
    first = blocks[0][1] if blocks else end
    rows = []
    for k in range(start + 1, first):
        line = doc.lines[k].strip()
        if doc.inside[k] or not line.startswith("|") or re.match(r"^\|[\s:|-]+\|?$", line):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if cells and cells[0] in ("항목", "표제", "제목"):
            continue
        if not any(STATE_CLOSED_RE.match(c) for c in cells[1:]):
            rows.append(cells[0])
    return entries, rows


def td_ticket_lists(doc, g):
    """{ticket: {field: items}} and the format violations of the four fields."""
    lists, out = {}, []
    for tid, num, title, f in doc.tickets:
        if tid in lists:
            continue
        lists[tid] = {}
        for key in TD_LIST_FIELDS:
            pred = {"설계 절": "T1", "잔여 항목": "T3", "미해결 항목": "T4"}[key]
            items, fault = parse_quoted(f.get(key))
            shape = [x for x in list_shape_faults(f, key) if x != "값이 비어 있음"]
            if fault or shape:
                out.append((pred, "%s %s 목록 형식 오류 %s" % (tid, key, "; ".join(([fault] if fault else []) + shape))))
            lists[tid][key] = items
    return lists, out


def check_assignment(pred, what, owned_lists, titles, out):
    """Each title is named by exactly one ticket, and each named item is one
    title."""
    count = dict((t, 0) for t in titles)
    for tid, items in owned_lists:
        for x in items:
            n = sum(1 for t in titles if t == x)
            if n == 0:
                out.append((pred, "%s 의 %s 항목에 맞는 표제 없음 「### %s」" % (tid, what, x)))
            elif n > 1:
                out.append((pred, "%s 의 %s 항목에 맞는 표제 %d개 「### %s」" % (tid, what, n, x)))
            else:
                count[x] += 1
    for t in titles:
        if count[t] == 0:
            out.append((pred, "%s 배정 없음 「### %s」" % (what, t)))
        elif count[t] > 1:
            out.append((pred, "%s 두 티켓 이상에 배정 「### %s」" % (what, t)))


def check_tickets_kind(doc, g):
    """T0–T5: the checks a ticket delivery design adds to D0–B1."""
    out = []
    # T0 — the split reason and the revision history.
    reason = doc.header.get("분할 사유")
    if reason is None or not reason.strip():
        out.append(("T0", "분할 사유 줄 없음"))
    elif "분할 사유" in getattr(doc.header, "dups", ()):
        out.append(("T0", "분할 사유 줄이 둘 이상"))
    hist = sum(1 for text, _, _ in doc.h2_sections() if text == HISTORY_HEADING)
    if hist != 1:
        out.append(("T0", "%s 표제 %d개 (정확히 하나여야 함)" % (HISTORY_HEADING, hist)))

    lists, faults = td_ticket_lists(doc, g)
    out.extend(faults)
    ids = [tid for tid in lists]

    # T1 — design sections.
    subs = [t for t, _, _ in arch_subsections(doc)]
    for tid in ids:
        for x in lists[tid]["설계 절"]:
            n = subs.count(x)
            if n == 0:
                out.append(("T1", "%s 설계 절에 맞는 표제 없음 「### %s」" % (tid, x)))
            elif n > 1:
                out.append(("T1", "%s 설계 절에 맞는 표제 %d개 「### %s」" % (tid, n, x)))
    named = set(x for tid in ids for x in lists[tid]["설계 절"])
    for t in subs:
        if t not in named:
            out.append(("T1", "어느 티켓도 이름 부르지 않은 설계 절 소절 「### %s」" % t))

    # T2 — child design and the fence of a ticket whose child design is skipped.
    for tid, num, title, f in doc.tickets:
        value = (f.get("하위 설계") or "").strip()
        if value not in SUB_DESIGN_VALUES:
            out.append(("T2", "%s 하위 설계 값 %s" % (tid, value or "(없음)")))
            continue
        if value != "생략 가능" or tid not in g.t:
            continue
        entries = []
        for key in FILE_LIST_FIELDS:
            for p in split_paths(f.get(key))[0]:
                if p == WHOLE_REPO or p.endswith("/") or any(ch in p for ch in GLOB_META):
                    out.append(("T2", "%s 생략 가능 티켓의 %s 항목이 파일 경로가 아님 %s" % (tid, key, p)))
                if p not in entries:
                    entries.append(p)
        if len(entries) > SKIPPABLE_MAX_FILES:
            out.append(("T2", "%s 생략 가능 티켓의 파일 %d개 (상한 %d)" % (tid, len(entries), SKIPPABLE_MAX_FILES)))
        if (any(posixpath.basename(p) == "SKILL.md" for p in entries)
                and "README.md" not in entries):
            out.append(("T2", "%s 생략 가능 티켓이 SKILL.md 를 담고 README.md 를 담지 않음" % tid))

    # T3 — residual items.
    rtitles = [t for t, _, _, _ in residual_items(doc)]
    check_assignment("T3", "잔여 항목", [(tid, lists[tid]["잔여 항목"]) for tid in ids], rtitles, out)

    # T4 — open unresolved entries.
    entries, rows = open_entries(doc)
    for r in rows:
        out.append(("T4", "표 행으로 적힌 열린 미해결 항목 %s" % r))
    check_assignment("T4", "미해결 항목", [(tid, lists[tid]["미해결 항목"]) for tid in ids],
                     [t for t, _, _ in entries], out)

    # T5 — every `§` of a residual item names a heading of this document.
    titles = heading_titles(doc)
    for t, n, i, j in residual_items(doc):
        for k in range(i + 1, j):
            line = doc.lines[k]
            pos = line.find("§")
            while pos != -1:
                if longest_heading(line[pos + 1:], titles) is None:
                    out.append(("T5", "R%d 의 § 참조에 맞는 표제 없음 %s" % (n, line[pos:pos + 20])))
                pos = line.find("§", pos + 1)
    return out


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
        self.started = set()      # (ticket id, run id)

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
            s = REG_STARTED_RE.match(line)
            if s:
                self.started.add((s.group(1), s.group(2)))
            elif b:
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

    def render(self, g, sha=None):
        """The registry bytes; `sha` replaces the document sha256 of the head
        (`record --started` keeps the value it read, `revise` writes the
        sha256 of the document it put in place)."""
        out = ["<!-- %s; doc=%s; doc-sha256=%s; tracker=%s; target=%s -->"
               % (REGISTRY_VERSION, doc_field(self.doc.path), sha or self.doc.sha256,
                  self.tracker, self.target)]
        if self.base:
            out.append("- `베이스` | 상태=%s | 참조=%s | 노드 id=%s" % self.base)
        for tid in sorted(self.tickets, key=lambda x: int(x[1:])):
            s = self.tickets[tid]
            out.append("- `티켓` | id=%s | 상태=%s | 참조=%s | 노드 id=%s | 유사 후보=%s"
                       % (tid, s[0], s[1], s[2], s[3]))
        for tid, run in sorted(self.started, key=lambda x: (int(x[0][1:]), x[1])):
            out.append("- `착수` | id=%s | 런=%s" % (tid, run))
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

    def write(self, g, sha=None):
        data = self.render(g, sha).encode("utf-8")
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


def external_edges(g, fdoc, origin, target):
    """{ticket: (preds, succs, skipped)} of existing tickets outside the split.

    The origin's waits-on become predecessors of every root ticket (no
    predecessor inside the split), its waiters successors of every leaf ticket
    (no successor inside the split); a ticket's `외부 선행`/`외부 후행` add to
    those. Every id must be in the snapshot. One the snapshot shows in another
    list is left out, with the reason, because the dependency tool refuses a
    pair outside the publishing list; a closed one in the same list stays.
    """
    waits_on, waiters = origin_edges(fdoc, origin) if origin else (set(), set())
    has_succ = set(p for t in g.ids for p in g.t[t]["deps"])
    snap = snapshot_of(fdoc)

    def elsewhere(x):
        lid = snap[x].get("list_id")
        return lid if isinstance(lid, str) and lid != target else None

    edges = {}
    for tid in g.ids:
        preds = set(g.t[tid]["ext_pred"]) | (waits_on if not g.t[tid]["deps"] else set())
        succs = set(g.t[tid]["ext_succ"]) | (waiters if tid not in has_succ else set())
        for x in sorted(preds | succs):
            if x not in snap:
                raise Refused("스냅숏에 없는 티켓 id %s (%s)" % (x, tid))
        skipped = [{"id": x, "direction": side, "reason": "다른 리스트 %s" % elsewhere(x)}
                   for side, ids in (("선행", preds), ("후행", succs))
                   for x in sorted(ids) if elsewhere(x)]
        edges[tid] = (sorted(x for x in preds if not elsewhere(x)),
                      sorted(x for x in succs if not elsewhere(x)), skipped)
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
        preds, succs, skipped = edges.get(key, ([], [], []))
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
                     "external_pred": preds, "external_succ": succs, "external_skipped": skipped}
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
            fplan = decide_fields(g, fdoc, origin, run_nodes, external_edges(g, fdoc, origin, target))
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


def say(line, err=False):
    stream = sys.stderr.buffer if err else sys.stdout.buffer
    stream.write((line + "\n").encode("utf-8"))
    stream.flush()


def refused(e):
    say("base-split.py: 거절 %s" % e, err=True)
    return 3


# --------------------------------------------------------------------------
# The revise lock and the registry opened by its head
# --------------------------------------------------------------------------

def lock_path(doc_path):
    a = os.path.abspath(doc_path)
    return os.path.join(os.path.dirname(a), os.path.basename(a) + ".revise.lock")


def take_lock(doc_path, run):
    """Take `<doc file name>.revise.lock` next to the document, without
    waiting; the run id and the time go in a file inside it."""
    path = lock_path(doc_path)
    try:
        os.mkdir(path)
    except FileExistsError:
        raise Refused("잠금이 이미 있음 %s" % path)
    except OSError as e:
        raise Refused("잠금을 잡지 못함 (%s)" % type(e).__name__)
    with open(os.path.join(path, "holder"), "wb") as f:
        f.write(("run=%s\ntime=%s\n" % (run, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
                .encode("utf-8"))
    return path


def drop_lock(path):
    holder = os.path.join(path, "holder")
    if os.path.exists(holder):
        os.unlink(holder)
    os.rmdir(path)


def open_registry_by_head(doc):
    """The registry of doc, its tracker and target read from its head line."""
    path = registry_path(doc.path)
    if not os.path.exists(path):
        raise Refused("등록부 없음 %s" % path)
    try:
        with open(path, "rb") as f:
            first = split_lines(f.read().decode("utf-8"))[:1]
    except (OSError, UnicodeDecodeError) as e:
        raise Refused("등록부를 읽지 못함 (%s)" % type(e).__name__)
    m = REG_HEAD_RE.match(first[0]) if first else None
    if not m:
        raise Refused("등록부 머리 줄을 읽지 못함")
    return Registry(doc, m.group(3), m.group(4)).load()


def ticket_ids(doc):
    return [tid for tid, _, _, _ in doc.tickets]


def cmd_record_started(args):
    for name in ("row", "entry", "plan", "state", "ref", "node_id", "similar"):
        if getattr(args, name) is not None:
            raise UsageError("--started takes no --%s" % name.replace("_", "-"))
    if args.doc_only:
        raise UsageError("--started takes no --doc-only")
    if not args.ticket or not args.run:
        raise UsageError("--started needs --ticket and --run")
    doc = Doc(args.doc)
    try:
        if doc.kind != "tickets":
            raise Refused("티켓 배달 설계 문서가 아님")
        if args.ticket not in ticket_ids(doc):
            raise Refused("문서에 없는 티켓 %s" % args.ticket)
        if not RUN_ID_RE.match(args.run):
            raise Refused("런 id 를 등록부에 쓸 수 없음")
        lock = take_lock(doc.path, args.run)
    except Refused as e:
        return refused(e)
    try:
        reg = open_registry_by_head(doc)
        key = (args.ticket, args.run)
        if key in reg.started:
            say("착수 이미 기록됨 %s %s" % key)
            return 0
        reg.started.add(key)
        reg.write(None, sha=reg.recorded_sha)
        say("기록 %s" % reg.path)
        return 0
    except Refused as e:
        return refused(e)
    finally:
        drop_lock(lock)


# --------------------------------------------------------------------------
# child-doc and fence-check
# --------------------------------------------------------------------------

BASE_CONSTRAINT_HEADING = "## 베이스 제약"
SLICE_HEAD_RE = re.compile(r"^### 슬라이스 (\S+) — (.+)$")
OUTSIDE_FIELD = "티켓 밖 파일"
OUTSIDE_ITEM_RE = re.compile(r"^- `([^`]+)` —(?: (.*))?$")
R_REF_RE = re.compile(r"(?<![A-Za-z0-9_])R(\d+)(?![A-Za-z0-9_])")


def ticket_block(doc, tid):
    sec = doc.section(SPLIT_HEADING)
    for t, i, j in doc.h3_blocks(*sec) if sec else []:
        m = TICKET_HEAD_RE.match(t)
        if m and m.group(1) == tid:
            return i, j
    return None


def contract_blocks(doc, ids):
    sec = doc.section(CONTRACT_SECTION)
    out = []
    for t, i, j in doc.h3_blocks(*sec) if sec else []:
        m = CONTRACT_HEAD_RE.match(t)
        if m and m.group(1) in ids:
            out.append((int(m.group(2)), i, j))
    return [(i, j) for _, i, j in sorted(out)]


def section_body(doc, heading):
    """The lines under a `## ` heading, with leading and trailing blank lines
    dropped, or None when the document has no such section."""
    sec = doc.section(heading)
    if sec is None:
        return None
    body = doc.block_lines(sec[0] + 1, sec[1])
    while body and not body[0].strip():
        body.pop(0)
    return body


def rewrite_residual(line, titles, moved, upper):
    """One pass over a residual body line: `§<heading>` becomes
    `상위 문서의 「<heading>」` (the longest heading that prefixes the text
    after `§`), a word-boundary `R<n>` becomes the new number of an item moved
    into the same child document or `상위 문서의 「### R<n>. …」`. The text put
    in is not scanned again."""
    out = []
    pos = 0
    while pos < len(line):
        if line[pos] == "§":
            t = longest_heading(line[pos + 1:], titles)
            if t is None:
                raise Refused("§ 참조에 맞는 상위 표제 없음 %s" % line[pos:pos + 20])
            out.append("상위 문서의 「%s」" % t)
            pos += 1 + len(t)
            continue
        m = R_REF_RE.match(line, pos)
        if m:
            n = int(m.group(1))
            if n in moved:
                out.append("R%d" % moved[n])
            elif n in upper:
                out.append("상위 문서의 「### %s」" % upper[n])
            else:
                raise Refused("상위 문서에 없는 항목 R%d" % n)
            pos = m.end()
            continue
        out.append(line[pos])
        pos += 1
    return "".join(out)


def build_child_doc(doc, g, tid, cutpoint):
    lists, _ = td_ticket_lists(doc, g)
    t = g.t[tid]
    f = next(x[3] for x in doc.tickets if x[0] == tid)
    blocks = []
    i, j = ticket_block(doc, tid)
    blocks.append(doc.block_lines(i, j))
    for i, j in contract_blocks(doc, set(t["provides"]) | set(t["consumes"])):
        blocks.append(doc.block_lines(i, j))
    for title, i, j in arch_subsections(doc):
        if title in lists[tid]["설계 절"]:
            blocks.append(doc.block_lines(i, j))
    decisions = section_body(doc, DECISIONS_HEADING)
    blocks.append([DECISIONS_COPY_HEADING, ""] + (decisions or ["없음"]))

    out = ["# %s" % t["title"], "", "**상태**: 동결됨", "", BASE_CONSTRAINT_HEADING, "",
           "**베이스 문서**: %s" % doc_field(doc.path),
           "**티켓**: %s" % tid,
           "**베이스 sha256**: %s" % doc.sha256]
    for b in blocks:
        out += [""] + b
    out += ["", ARCH_HEADING, "", LINKAGE_SENTENCE, "", CHILD_SENTENCE]

    out += ["", "## 미해결 이슈 / 트레이드오프", ""]
    entries, _ = open_entries(doc)
    mine = [(i, j) for title, i, j in entries if title in lists[tid]["미해결 항목"]]
    if mine:
        for k, (i, j) in enumerate(mine):
            out += ([""] if k else []) + doc.block_lines(i, j)
    else:
        out.append("없음")

    items = residual_items(doc)
    upper = dict((n, title) for title, n, _, _ in items)
    taken = [(title, n, i, j) for title, n, i, j in items if title in lists[tid]["잔여 항목"]]
    moved = dict((n, k + 1) for k, (_, n, _, _) in enumerate(taken))
    titles = heading_titles(doc)
    new_heads = []
    if taken:
        out += ["", RESIDUAL_HEADING]
        for title, n, i, j in taken:
            head = "R%d. %s" % (moved[n], R_HEAD_RE.match("### " + title).group(2))
            new_heads.append(head)
            out += ["", "### " + head]
            out += [rewrite_residual(x, titles, moved, upper) for x in doc.block_lines(i + 1, j)]

    declared = []
    for p in t["owned"] + t["shared"]:
        if p not in declared:
            declared.append(p)
    count = 1 if CUTPOINTS.index(cutpoint) >= CUTPOINTS.index("PR") else 0
    out += ["", SLICING_HEADING, "", "**슬라이스 수**: %d" % count, "",
            "### 슬라이스 A — %s" % t["title"],
            "**스킬**: implement",
            "**레포**: %s" % strip_code(f.get("레포") or "").strip(),
            "**선언 파일**: %s" % ", ".join("`%s`" % p for p in declared),
            "**선행**: 없음",
            "**머지 순서**: 없음",
            "**절단점**: %s" % cutpoint,
            "**잔여 항목**: %s" % quoted_list(new_heads)]
    return "".join(x + "\n" for x in out).encode("utf-8")


def outside_entries(doc, start, end):
    """({path: reason}, faults) of the `**티켓 밖 파일**` field of one slice
    block: `없음`, or an empty field line with one `` - `<path>` — <reason> ``
    bullet per line under it. A block without the field has none."""
    entries, faults = {}, []
    k = next((x for x in range(start, end) if not doc.inside[x]
              and FIELD_RE.match(doc.lines[x]) and FIELD_RE.match(doc.lines[x]).group(1) == OUTSIDE_FIELD), None)
    if k is None:
        return entries, faults
    value = (FIELD_RE.match(doc.lines[k]).group(2) or "").strip()
    under = []
    x = k + 1
    while x < end and (doc.inside[x] or not FIELD_RE.match(doc.lines[x])):
        if doc.lines[x].strip():
            under.append(doc.lines[x])
        x += 1
    if value == "없음":
        if under:
            faults.append("%s 이 없음 인데 아래 줄이 있음" % OUTSIDE_FIELD)
        return entries, faults
    if value:
        faults.append("%s 값 꼴 어긋남 %s" % (OUTSIDE_FIELD, value))
        return entries, faults
    if not under:
        faults.append("%s 항목이 비어 있음" % OUTSIDE_FIELD)
    for line in under:
        m = OUTSIDE_ITEM_RE.match(line.rstrip())
        if not m:
            faults.append("%s 줄 꼴 어긋남 %s" % (OUTSIDE_FIELD, line.strip()))
        elif not (m.group(2) or "").strip():
            faults.append("%s 사유 없음 %s" % (OUTSIDE_FIELD, m.group(1)))
        else:
            entries[norm_path(m.group(1))] = m.group(2).strip()
    return entries, faults


def fence_faults(doc):
    """The `F1` details of a child document: every declared file of every
    slice is inside the ticket's owned and shared files or one of that
    slice's `**티켓 밖 파일**` entries."""
    out = []
    fence = None
    sec = doc.section(BASE_CONSTRAINT_HEADING)
    if sec is None:
        out.append("표제 없음 %s" % BASE_CONSTRAINT_HEADING)
    else:
        tblocks = [(i, j) for t, i, j in doc.h3_blocks(*sec) if TICKET_HEAD_RE.match(t)]
        if len(tblocks) != 1:
            out.append("%s 의 티켓 블록 %d개 (정확히 하나여야 함)" % (BASE_CONSTRAINT_HEADING, len(tblocks)))
        else:
            f = parse_block(doc.lines, doc.inside, tblocks[0][0] + 1, tblocks[0][1])
            fence = []
            for key in FILE_LIST_FIELDS:
                entries, faults = split_paths(f.get(key))
                if key == "소유 파일" and f.get(key) is None:
                    faults.append("필드 없음")
                for x in faults:
                    out.append("티켓 블록 %s %s" % (key, x))
                fence += entries
    sl = doc.section(SLICING_HEADING)
    if sl is None:
        out.append("표제 없음 %s" % SLICING_HEADING)
        return out
    slices = [(t, i, j) for t, i, j in doc.h3_blocks(*sl) if t.startswith("### 슬라이스 ")]
    if not slices:
        out.append("슬라이스 블록 없음")
    for t, i, j in slices:
        m = SLICE_HEAD_RE.match(t)
        sid = m.group(1) if m else t[4:]
        f = parse_block(doc.lines, doc.inside, i + 1, j)
        if f.get("선언 파일") is None:
            out.append("슬라이스 %s 선언 파일 필드 없음" % sid)
        declared, faults = split_paths(f.get("선언 파일"))
        for x in faults:
            out.append("슬라이스 %s 선언 파일 %s" % (sid, x))
        outside, faults = outside_entries(doc, i + 1, j)
        for x in faults:
            out.append("슬라이스 %s %s" % (sid, x))
        for p in declared:
            inside = fence is not None and any(covered_by(p, s) for s in fence)
            if not inside and p not in outside:
                out.append("슬라이스 %s 울타리 밖 선언 파일 %s" % (sid, p))
        for p in sorted(outside):
            if p not in declared:
                out.append("슬라이스 %s 선언 파일에 없는 %s 항목 %s" % (sid, OUTSIDE_FIELD, p))
    return out


def cmd_fence_check(args):
    doc = Doc(args.doc)
    lines = ["F1 %s" % x for x in fence_faults(doc)]
    for line in lines:
        say(line)
    return 1 if lines else 0


def cmd_child_doc(args):
    doc = Doc(args.doc)
    try:
        if doc.kind != "tickets":
            raise Refused("티켓 배달 설계 문서가 아님")
        if args.cutpoint not in CUTPOINTS:
            raise Refused("절단점 %s 이 절단점 어휘 밖" % args.cutpoint)
        violations, g = run_checks(doc)
        if violations:
            raise Refused("상위 문서 점검 위반 %d건 — check 로 확인" % len(violations))
        if args.ticket not in g.t:
            raise Refused("문서에 없는 티켓 %s" % args.ticket)
        f = next(x[3] for x in doc.tickets if x[0] == args.ticket)
        if (f.get("하위 설계") or "").strip() != "생략 가능":
            raise Refused("%s 의 하위 설계가 생략 가능 이 아님" % args.ticket)
        if os.path.lexists(args.out):
            raise Refused("--out 이 이미 있음")
        data = build_child_doc(doc, g, args.ticket, args.cutpoint)
        faults = fence_faults(Doc(args.out, raw=data))
        if faults:
            raise Refused("만든 문서가 fence-check 를 통과하지 못함 — %s" % "; ".join(faults))
        out_dir = os.path.dirname(os.path.abspath(args.out))
        if not os.path.isdir(out_dir):
            raise Refused("--out 의 디렉터리가 없음")
    except Refused as e:
        return refused(e)
    write_atomic(os.path.abspath(args.out), data)
    say("하위 문서 %s" % args.out)
    return 0


# --------------------------------------------------------------------------
# revise
# --------------------------------------------------------------------------

REVISION_HEAD_RE = re.compile(r"^### 개정 (\d+) — (\d{4}-\d{2}-\d{2}) · 런 (\S+) · 티켓 (T\d+)$")
REVISION_FIELDS = ("바꾼 절", "영향 티켓", "완료 티켓 차이")
P_FIELDS = TD_FIELDS
UNSTARTED_FIELDS = ("소유 파일", "공유 파일", "중첩 사유")


def trimmed(seg):
    seg = list(seg)
    while seg and not seg[-1].strip():
        seg.pop()
    return seg


def blocks_by_head(doc, sec):
    """(lines before the first `###`, [(heading, lines)]) of one section."""
    if sec is None:
        return [], []
    start, end = sec
    blocks = doc.h3_blocks(start, end)
    first = blocks[0][1] if blocks else end
    return trimmed(doc.lines[start + 1:first]), [(t, trimmed(doc.lines[i:j])) for t, i, j in blocks]


def revision_entry(old, new, ticket, run):
    """(changed-sections value, fault) of the one entry the candidate's
    `## 개정 이력` adds to the old one."""
    o = section_body(old, HISTORY_HEADING)
    n = section_body(new, HISTORY_HEADING)
    if o is None or n is None:
        return None, "%s 표제 없음" % HISTORY_HEADING
    prefix = [] if [x for x in o if x.strip()] == ["없음"] else o
    if n[:len(prefix)] != prefix:
        return None, "%s 의 앞 내용이 바뀜" % HISTORY_HEADING
    rest = n[len(prefix):]
    while rest and not rest[0].strip():
        rest.pop(0)
    heads = [k for k, x in enumerate(rest) if x.startswith("### ")]
    if not rest or heads != [0]:
        return None, "새 개정 항목이 정확히 하나가 아님 (%d개)" % len(heads)
    m = REVISION_HEAD_RE.match(rest[0])
    sec = old.section(HISTORY_HEADING)
    count = len(old.h3_blocks(*sec))
    if not m:
        return None, "새 개정 항목 표제 꼴 어긋남 %s" % rest[0]
    if int(m.group(1)) != count + 1:
        return None, "새 개정 항목 번호 %s ≠ %d" % (m.group(1), count + 1)
    if m.group(3) != run or m.group(4) != ticket:
        return None, "새 개정 항목의 런·티켓이 --run·--ticket 과 다름"
    fields = parse_block(rest, mark_fences(rest), 1, len(rest))
    for key in REVISION_FIELDS:
        if not (fields.get(key) or "").strip():
            return None, "새 개정 항목에 %s 없음" % key
        if key in fields.dups:
            return None, "새 개정 항목에 %s 가 둘 이상" % key
    return fields["바꾼 절"], None


def revise_faults(old, new, own, started, changed):
    """Why the candidate changes the document outside what this ticket's
    child run may change, or []."""
    out = []
    ever = set(tid for tid, _ in started)
    gold, gnew = Graph(old), Graph(new)
    lold, _ = td_ticket_lists(old, gold)
    lnew, _ = td_ticket_lists(new, gnew)
    p = set([own]) | set(t for t in ticket_ids(new) + ticket_ids(old) if t not in ever)

    def holders(field, title):
        return set(t for lists in (lold, lnew) for t in lists if title in lists[t][field])

    def first_lines(doc):
        h2 = doc.h2_sections()
        return trimmed(doc.lines[:h2[0][1]] if h2 else doc.lines)

    if first_lines(old) != first_lines(new):
        out.append("첫 ## 앞 머리가 바뀜")
    heads_old = [t for t, _, _ in old.h2_sections()]
    heads_new = [t for t, _, _ in new.h2_sections()]
    if heads_old != heads_new:
        out.append("## 표제 순서가 바뀜")
        return out
    unresolved = unresolved_section(old)
    unresolved_head = old.lines[unresolved[0]] if unresolved else None

    for k, (head, i, end) in enumerate(old.h2_sections()):
        _, ni, nend = new.h2_sections()[k]
        if trimmed(old.lines[i:end]) == trimmed(new.lines[ni:nend]):
            continue
        name = head[3:]
        pre_o, blk_o = blocks_by_head(old, (i, end))
        pre_n, blk_n = blocks_by_head(new, (ni, nend))
        if head == SPLIT_HEADING:
            if pre_o != pre_n:
                out.append("%s 머리가 바뀜" % head)
            if [t for t, _ in blk_o] != [t for t, _ in blk_n]:
                out.append("%s 의 블록 집합·순서가 바뀜" % head)
                continue
            for (t, lo), (_, ln) in zip(blk_o, blk_n):
                m = TICKET_HEAD_RE.match(t)
                if not m:
                    if lo != ln:
                        out.append("%s 가 바뀜" % t)
                    continue
                tid = m.group(1)
                allowed = set()
                if tid in p:
                    allowed |= set(P_FIELDS)
                if tid not in ever:
                    allowed |= set(UNSTARTED_FIELDS)
                uo = [u for u in field_units_of(lo) if u[0] not in allowed]
                un = [u for u in field_units_of(ln) if u[0] not in allowed]
                if uo != un:
                    diff = [u for u in uo if u not in un] + [u for u in un if u not in uo]
                    keys = sorted(set(u[0] or "(머리)" for u in diff))
                    out.append("%s 의 바꿀 수 없는 필드가 바뀜 %s" % (tid, ", ".join(keys) or "(순서)"))
            for tid in ticket_ids(new):
                if tid in ever or tid not in gnew.t or tid not in gold.t:
                    continue
                added = [x for x in gnew.t[tid]["owned"] + gnew.t[tid]["shared"]
                         if x not in gold.t[tid]["owned"] + gold.t[tid]["shared"]]
                for s in sorted(ever):
                    if s not in gnew.t or gnew.t[s]["repo"] != gnew.t[tid]["repo"]:
                        continue
                    for x in added:
                        for q in gnew.t[s]["owned"]:
                            if paths_overlap(x, q):
                                out.append("%s 에 더한 %s 가 착수한 %s 의 소유 파일 %s 와 겹침" % (tid, x, s, q))
        elif head == ARCH_HEADING:
            if pre_o != pre_n:
                out.append("%s 의 첫 ### 앞 줄이 바뀜" % head)
            if [t for t, _ in blk_o] != [t for t, _ in blk_n]:
                out.append("%s 의 소절 순서가 바뀜" % head)
                continue
            for (t, lo), (_, ln) in zip(blk_o, blk_n):
                if lo == ln:
                    continue
                who = holders("설계 절", t[4:])
                if who - p:
                    out.append("설계 절 소절 「%s」 을 이름 부르는 티켓 %s 가 바꿀 수 있는 티켓이 아님"
                               % (t, ", ".join(sorted(who - p, key=lambda x: int(x[1:])))))
        elif head == DECISIONS_HEADING:
            if "주요 결정사항과 근거" not in (changed or ""):
                out.append("%s 가 바뀌었는데 바꾼 절 이 그 절을 적지 않음" % head)
        elif head == unresolved_head or head == RESIDUAL_HEADING:
            field = "잔여 항목" if head == RESIDUAL_HEADING else "미해결 항목"
            if pre_o != pre_n:
                out.append("%s 의 첫 ### 앞 줄이 바뀜" % head)
            do, dn = dict(blk_o), dict(blk_n)
            for t in sorted(set(do) | set(dn)):
                if do.get(t) == dn.get(t):
                    continue
                who = holders(field, t[4:])
                if not who:
                    out.append("배정 없는 항목 「%s」 이 바뀜" % t)
                elif who - p:
                    out.append("항목 「%s」 을 배정받은 티켓 %s 가 바꿀 수 있는 티켓이 아님"
                               % (t, ", ".join(sorted(who - p, key=lambda x: int(x[1:])))))
                if name not in (changed or "") and t[4:] not in (changed or ""):
                    out.append("항목 「%s」 이 바뀌었는데 바꾼 절 이 그 절이나 항목을 적지 않음" % t)
        elif head == HISTORY_HEADING:
            continue
        else:
            out.append("%s 는 바꿀 수 없는 절" % head)
    return out


def field_units_of(lines):
    """[(key, lines)] of one block: a unit is a field line outside fences and
    every line under it up to the next such line; the lines before the first
    field line (the heading) are the unit of key None."""
    inside = mark_fences(lines)
    units = [(None, [])]
    for k, line in enumerate(lines):
        m = FIELD_RE.match(line) if not inside[k] else None
        if m:
            units.append((m.group(1), []))
        units[-1][1].append(line)
    return [(key, trimmed(x)) for key, x in units]


def cmd_revise(args):
    for name in ("from_", "to", "ticket", "run"):
        if not getattr(args, name):
            raise UsageError("revise needs --from, --to, --ticket and --run")
    doc = Doc(args.doc)
    try:
        if doc.kind != "tickets":
            raise Refused("티켓 배달 설계 문서가 아님")
        if not RUN_ID_RE.match(args.run):
            raise Refused("런 id 꼴 어긋남")
        lock = take_lock(doc.path, args.run)
    except Refused as e:
        return refused(e)
    replacing = False
    try:
        old = Doc(args.from_)
        new = Doc(args.to)
        # 1 — the document is still the copy the revision started from.
        if doc.sha256 != old.sha256:
            raise Refused("상위 문서의 sha256 이 --from 과 다름")
        # 2 — this run started this ticket.
        reg = open_registry_by_head(doc)
        if (args.ticket, args.run) not in reg.started:
            raise Refused("등록부에 %s 의 런 %s 착수 행이 없음" % (args.ticket, args.run))
        env_run = os.environ.get("CC_PIPELINE_RUN_ID")
        if env_run and env_run != args.run:
            raise Refused("--run 이 이 런의 run id 와 다름")
        # 4 — exactly one new revision entry (its changed sections bound 3).
        changed, fault = revision_entry(old, new, args.ticket, args.run)
        if fault:
            raise Refused(fault)
        # 3 — every change is inside what this ticket's child run may change.
        faults = revise_faults(old, new, args.ticket, reg.started, changed)
        if faults:
            raise Refused("허용 영역 밖 변경 — %s" % "; ".join(faults))
        # 5 — the candidate passes check.
        if new.kind != "tickets":
            raise Refused("후보가 티켓 배달 설계 문서가 아님")
        violations, _ = run_checks(new)
        if violations:
            raise Refused("후보 점검 위반 %d건 — check 로 확인" % len(violations))
        # 6 — the document first, then the registry head.
        replacing = True
        write_atomic(os.path.abspath(doc.path), new.raw)
        reg.write(None, sha=new.sha256)
    except Refused as e:
        if not replacing:
            drop_lock(lock)
        return refused(e)
    except BaseException:
        if not replacing:
            drop_lock(lock)
        else:
            say("base-split.py: 거절 교체 중 실패 — 잠금 %s 을 남김" % lock, err=True)
            return 3
        raise
    drop_lock(lock)
    say("개정 %s %s → %s" % (args.doc, doc.sha256, new.sha256))
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
    # Required unless --started; cmd_record checks it.
    r.add_argument("--row")
    r.add_argument("--doc-only", action="store_true")
    r.add_argument("--entry")
    r.add_argument("--plan")
    r.add_argument("--state", choices=("발행중", "발행됨", "없음"))
    r.add_argument("--ref")
    r.add_argument("--node-id")
    r.add_argument("--similar")
    r.add_argument("--started", action="store_true")
    r.add_argument("--ticket")
    r.add_argument("--run")
    d = sub.add_parser("child-doc", allow_abbrev=False)
    d.add_argument("doc")
    d.add_argument("--ticket", required=True)
    d.add_argument("--cutpoint", required=True)
    d.add_argument("--out", required=True)
    fc = sub.add_parser("fence-check", allow_abbrev=False)
    fc.add_argument("doc")
    rv = sub.add_parser("revise", allow_abbrev=False)
    rv.add_argument("doc")
    rv.add_argument("--from", dest="from_", required=True)
    rv.add_argument("--to", required=True)
    rv.add_argument("--ticket", required=True)
    rv.add_argument("--run", required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "record" and not args.started:
        if args.row is None:
            sys.stderr.write("base-split.py record: error: the following arguments are required: --row\n")
            return 2
        if args.ticket is not None or args.run is not None:
            sys.stderr.write("base-split.py record: error: --ticket and --run go with --started\n")
            return 2
    try:
        if args.command == "check":
            return cmd_check(args)
        if args.command == "plan":
            return cmd_plan(args)
        if args.command == "child-doc":
            return cmd_child_doc(args)
        if args.command == "fence-check":
            return cmd_fence_check(args)
        if args.command == "revise":
            return cmd_revise(args)
        if args.started:
            return cmd_record_started(args)
        return cmd_record(args)
    except UsageError as e:
        sys.stderr.write("base-split.py: %s\n" % e)
        return 2
    except Exception as e:  # never echo document or registry bytes
        sys.stderr.write("base-split.py: internal error (%s)\n" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
