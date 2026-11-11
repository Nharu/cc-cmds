#!/usr/bin/env python3
"""Move superseded and settled prose of a design document into its archive.

    doc-tidy.py plan    DOC [--reviewed FROZEN]
    doc-tidy.py apply   DOC --archive ARCHIVE --doc-key KEY --writer NAME [--since BASE] [--reviewed FROZEN]
    doc-tidy.py unmark  DOC --archive ARCHIVE --doc-key KEY --writer NAME --since BASE
    doc-tidy.py check   BEFORE AFTER ARCHIVE
    doc-tidy.py tidy    DOC --archive ARCHIVE --doc-key KEY --writer NAME --below BYTES [--reviewed FROZEN]

Rule T1 moves every superseded-sentence parenthesis ` (대체된 문장: "...")` into
an `### A<n>` piece and leaves ` (보관 A<n>)` in its place. Rule T3 moves, from a
settled entry of `## 미해결 이슈 / 트레이드오프` (a `**상태**: 해결` line and a
line starting with `해결:`), the field lines `**구현 처분**`, `**닿는 슬라이스**`
and `**재량 기준**` together with the discussion between the field block and the
`해결:` line into a `### B<n>` piece, and leaves `**보관**: B<n>` right above the
`해결:` line. The field block starts at the first line after the heading that is
not empty, not a line holding only the unreviewed marker and not a `> ` line
that keeps an old heading. T3 takes an entry only when those lines form one
contiguous run and no field line outside the three (`**상태**`, `**사유**` and
the rest) lies inside it. Every verb that transforms refuses, writing nothing,
when an entry holding `**상태**: 해결` before the transform would hold none
after it. `unmark` removes the unreviewed marker `**미리뷰(스톱 이후 추가)**` and the one
space after it from every line that the base document holds byte for byte, and
keeps the line as it was in a `### C<n>` piece.

Nothing is touched inside a code fence, at a match whose start lies inside a
backtick code span, on an unreviewed marker line (T1, and T3 for the run it
would move), in an entry with `**사유 거둠**` or `**보관**:`, or in an entry whose
lines to move are not contiguous. `check` uses the same definitions. A marker
line is unreviewed when `--reviewed FROZEN` (the copy the last audit read) does
not hold it byte for byte, and every marker line is unreviewed without
`--reviewed`. A reviewed marker line is moved with its marker; only `unmark`
removes a marker.

`plan` prints the counts and bytes each rule would move and the expected size.
`apply` and `unmark` run the `check` comparison in memory and write only when
it passes, the archive first and the document second, each by an atomic
rename; with nothing to move they write nothing. New A and B numbers start past
both the archive's numbers and the markers the document already shows. `--since BASE`
narrows T1 to parentheses BASE does not hold byte for byte and T3 to entries
whose heading BASE does not show settled; a heading that appears twice in
either document is left alone. `check` expands the markers of the archive's
last block in AFTER and compares the result with BEFORE (with the C pieces of
that block unmarked) byte for byte. `tidy` reads DOC once, refuses when the
expected or the resulting size is at or above BYTES, runs the `check`
comparison in memory, and writes only when everything passes; it prints the
sha256 of the document before and after.

The archive is a file of its own kind: line 1 is an H1, line 2 is
`<!-- cc-design-archive v1; writer=doc-tidy; owner-doc=<KEY> -->`. An existing
archive whose line 2 is not that form or names another KEY is refused. The
caller holds the document lock; this script takes none.

Exit codes: 0 success, 1 check failed or refused (nothing written), 2 usage.

Run it by path, with no interpreter in front: the gate grades the basename
and the subcommand, and an interpreter prefix is graded as an opaque write.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import hashlib  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402

MARKER = "**미리뷰(스톱 이후 추가)**"
T1_RE = re.compile(r' ?\(대체된 문장: ".*?"\)')
SECTION_UNRESOLVED = "## 미해결 이슈 / 트레이드오프"
STATE_SETTLED = "**상태**: 해결"
MOVABLE_FIELDS = ("구현 처분", "닿는 슬라이스", "재량 기준")
FIELD_RE = re.compile(r"^\*\*([^*]+)\*\*:(?: .*)?$")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
ARCHIVE_HEAD_RE = re.compile(
    r"^<!-- cc-design-archive (v\d+); writer=doc-tidy; owner-doc=(.+) -->$")
ARCHIVE_VERSION = "v1"
PIECE_HEAD_RE = re.compile(r"^### ([ABC])([0-9]+)$")
BLOCK_HEAD_RE = re.compile(r"^## 정리 ")
BACKTICK_RUN_RE = re.compile(r"`+")


class Refused(Exception):
    pass


# ---------------------------------------------------------------- text basics

def read_text(path):
    with open(path, "rb") as f:
        data = f.read()
    return data, data.decode("utf-8")


def split_lines(text):
    """Lines without their terminator; the last element is what follows the
    last newline (empty when the text ends with one)."""
    return text.split("\n")


def join_lines(lines):
    return "\n".join(lines)


def fence_mask(lines):
    """True for every line that is a fence line or lies inside a fence."""
    mask = []
    fence = None
    for line in lines:
        if fence is None:
            m = FENCE_RE.match(line)
            if m:
                fence = m.group(1)
                mask.append(True)
                continue
            mask.append(False)
        else:
            mask.append(True)
            body = line.strip()
            indent = len(line) - len(line.lstrip(" "))
            if indent <= 3 and len(body) >= len(fence) and body == fence[0] * len(body):
                fence = None
    return mask


def code_spans(line):
    """Half-open [start, end) ranges of backtick code spans in one line."""
    spans = []
    runs = [(m.start(), m.end()) for m in BACKTICK_RUN_RE.finditer(line)]
    i = 0
    while i < len(runs):
        s, e = runs[i]
        n = e - s
        j = i + 1
        while j < len(runs) and runs[j][1] - runs[j][0] != n:
            j += 1
        if j < len(runs):
            spans.append((s, runs[j][1]))
            i = j + 1
        else:
            i += 1
    return spans


def in_span(pos, spans):
    return any(s <= pos < e for s, e in spans)


def marker_positions(line):
    """Start positions of the unreviewed marker outside code spans."""
    spans = code_spans(line)
    out = []
    pos = line.find(MARKER)
    while pos != -1:
        if not in_span(pos, spans):
            out.append(pos)
        pos = line.find(MARKER, pos + 1)
    return out


def has_marker(line):
    return bool(marker_positions(line))


def unreviewed(line, reviewed_lines):
    """True for a marker line no review has read: with a frozen copy, one the
    copy does not hold byte for byte; without one, every marker line."""
    if not has_marker(line):
        return False
    return reviewed_lines is None or line not in reviewed_lines


def unmark_line(line):
    """Remove every marker outside a code span and the one space after it."""
    positions = marker_positions(line)
    if not positions:
        return line
    out = []
    last = 0
    for pos in positions:
        out.append(line[last:pos])
        end = pos + len(MARKER)
        if line[end:end + 1] == " ":
            end += 1
        last = end
    out.append(line[last:])
    return "".join(out)


def t1_matches(line):
    """(start, end) of T1 fragments in one line, skipping code-span starts."""
    spans = code_spans(line)
    out = []
    pos = 0
    while True:
        m = T1_RE.search(line, pos)
        if not m:
            break
        paren = line.index("(", m.start())
        if in_span(paren, spans):
            pos = paren + 1
            continue
        out.append((m.start(), m.end()))
        pos = m.end()
    return out


# ------------------------------------------------------------- T3 entries

def unresolved_entries(lines, mask):
    """Yield (heading_index, end_index) of `### ` entries in the unresolved
    section, end exclusive."""
    in_section = False
    entries = []
    start = None
    for i, line in enumerate(lines):
        if mask[i]:
            continue
        if line.startswith("## ") and not line.startswith("### "):
            if start is not None:
                entries.append((start, i))
                start = None
            in_section = (line.rstrip() == SECTION_UNRESOLVED)
            continue
        if not in_section:
            continue
        if line.startswith("### "):
            if start is not None:
                entries.append((start, i))
            start = i
    if start is not None:
        entries.append((start, len(lines)))
    return entries


def entry_is_settled(lines, mask, h, end):
    has_state = any(lines[k] == STATE_SETTLED for k in range(h + 1, end) if not mask[k])
    has_res = any(lines[k].startswith("해결:") for k in range(h + 1, end) if not mask[k])
    return has_state and has_res


def heading_counts(lines, mask):
    counts = {}
    for h, end in unresolved_entries(lines, mask):
        counts[lines[h]] = counts.get(lines[h], 0) + 1
    return counts


def t3_region(lines, mask, h, end, reviewed_lines=None):
    """(first, last_exclusive, resolution_index) of the run T3 moves, or None."""
    if not entry_is_settled(lines, mask, h, end):
        return None
    body = range(h + 1, end)
    for k in body:
        if mask[k]:
            continue
        if lines[k].startswith("**보관**:") or lines[k].startswith("**사유 거둠**"):
            return None
    res = next(k for k in body if not mask[k] and lines[k].startswith("해결:"))
    block_start = h + 1
    while block_start < res and is_field_block_lead(lines[block_start]):
        block_start += 1
    chunk_end = block_start
    while chunk_end < res and FIELD_RE.match(lines[chunk_end]):
        chunk_end += 1
    first = None
    for k in range(block_start, chunk_end):
        m = FIELD_RE.match(lines[k])
        if m and m.group(1) in MOVABLE_FIELDS:
            first = k
            break
    if first is None:
        first = chunk_end
    if first >= res:
        return None
    for k in range(first, res):
        m = FIELD_RE.match(lines[k])
        if m and m.group(1) not in MOVABLE_FIELDS:
            return None
        if unreviewed(lines[k], reviewed_lines):
            return None
    return first, res, res


def is_field_block_lead(line):
    """True for a line that may stand between an entry heading and its field
    block: an empty line, a line holding only the unreviewed marker, or a
    `> ` line that keeps an old heading."""
    return line.strip() == "" or line.strip() == MARKER or line.startswith("> ")


def settled_state_headings(lines, mask):
    """Sorted headings of the unresolved entries that hold a `**상태**: 해결`
    line, one element per entry."""
    out = []
    for h, end in unresolved_entries(lines, mask):
        if any(lines[k] == STATE_SETTLED for k in range(h + 1, end) if not mask[k]):
            out.append(lines[h])
    return sorted(out)


def settled_headings(lines, mask):
    out = set()
    for h, end in unresolved_entries(lines, mask):
        if entry_is_settled(lines, mask, h, end):
            out.add(lines[h])
    return out


# ------------------------------------------------------------- transforms

def reviewed_set(reviewed_text):
    return None if reviewed_text is None else set(split_lines(reviewed_text))


def transform_apply(text, base_text, next_a, next_b, reviewed_text=None):
    """Return (new_text, pieces) with pieces [(kind, n, heading, content)].

    content of A is the fragment, of B the moved lines with their newlines.
    reviewed_text is the frozen copy the last audit read; a marker line it
    holds byte for byte is moved like any other line."""
    reviewed_lines = reviewed_set(reviewed_text)
    lines = split_lines(text)
    mask = fence_mask(lines)
    pieces = []

    base_settled = None
    base_counts = None
    if base_text is not None:
        blines = split_lines(base_text)
        bmask = fence_mask(blines)
        base_settled = settled_headings(blines, bmask)
        base_counts = heading_counts(blines, bmask)
    doc_counts = heading_counts(lines, mask)

    regions = []
    for h, end in unresolved_entries(lines, mask):
        r = t3_region(lines, mask, h, end, reviewed_lines)
        if r is None:
            continue
        head = lines[h]
        if base_text is not None:
            if doc_counts.get(head, 0) > 1 or base_counts.get(head, 0) > 1:
                continue
            if head in base_settled:
                continue
        regions.append((h, r[0], r[1]))

    out = []
    moved_ranges = {}
    for h, first, res in regions:
        moved_ranges[first] = (h, res)
    i = 0
    n_lines = len(lines)
    moved_mask = [False] * n_lines
    while i < n_lines:
        if i in moved_ranges:
            h, res = moved_ranges[i]
            content = "".join(line + "\n" for line in lines[i:res])
            pieces.append(("B", next_b, lines[h], content))
            out.append("**보관**: B%d" % next_b)
            next_b += 1
            for k in range(i, res):
                moved_mask[k] = True
            i = res
            continue
        out.append(lines[i])
        i += 1

    # T1 on the lines left in place.
    out_mask = fence_mask(out)
    final = []
    for idx, line in enumerate(out):
        if out_mask[idx] or unreviewed(line, reviewed_lines):
            final.append(line)
            continue
        matches = t1_matches(line)
        if not matches:
            final.append(line)
            continue
        buf = []
        last = 0
        for s, e in matches:
            frag = line[s:e]
            paren = frag[frag.index("("):]
            if base_text is not None and paren in base_text:
                continue
            buf.append(line[last:s])
            buf.append(" (보관 A%d)" % next_a)
            pieces.append(("A", next_a, None, frag))
            next_a += 1
            last = e
        buf.append(line[last:])
        final.append("".join(buf))
    pieces.sort(key=lambda p: (p[0], p[1]))
    if settled_state_headings(final, fence_mask(final)) != settled_state_headings(lines, mask):
        raise Refused("정리 뒤 문서에서 `**상태**: 해결` 줄이 빠진 항목이 생김")
    return join_lines(final), pieces


def transform_unmark(text, base_text, next_c):
    lines = split_lines(text)
    mask = fence_mask(lines)
    base_lines = set(split_lines(base_text))
    pieces = []
    out = []
    for i, line in enumerate(lines):
        if not mask[i] and has_marker(line) and line in base_lines:
            pieces.append(("C", next_c, None, line))
            next_c += 1
            out.append(unmark_line(line))
        else:
            out.append(line)
    return join_lines(out), pieces


# ------------------------------------------------------------- archive

def archive_head(key):
    return "<!-- cc-design-archive %s; writer=doc-tidy; owner-doc=%s -->" % (ARCHIVE_VERSION, key)


def load_archive(path, key):
    """Return the existing archive text ('' when absent); refuse a foreign one."""
    if not os.path.exists(path):
        return ""
    _, text = read_text(path)
    lines = split_lines(text)
    if len(lines) < 2 or not lines[0].startswith("# "):
        raise Refused("보관 파일 머리 꼴이 아님: %s" % path)
    m = ARCHIVE_HEAD_RE.match(lines[1])
    if not m:
        raise Refused("보관 파일 2행이 cc-design-archive 꼴이 아님: %s" % path)
    if m.group(1) != ARCHIVE_VERSION:
        raise Refused("보관 파일 판 토큰이 %s 가 아님: %s" % (ARCHIVE_VERSION, m.group(1)))
    if m.group(2) != key:
        raise Refused("보관 파일 owner-doc=%s 가 문서 키 %s 와 다름" % (m.group(2), key))
    return text


def parse_archive(text):
    """Return a list of blocks; each block is a list of (kind, n, heading, content)."""
    lines = split_lines(text)
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if BLOCK_HEAD_RE.match(line):
            blocks.append([])
            i += 1
            continue
        m = PIECE_HEAD_RE.match(line)
        if m and blocks:
            kind, n = m.group(1), int(m.group(2))
            i += 1
            heading = None
            if kind == "B" and i < len(lines) and lines[i].startswith("항목: "):
                heading = lines[i][len("항목: "):]
                i += 1
            if i >= len(lines) or not re.match(r"^`{3,}$", lines[i]):
                raise Refused("보관 조각 %s%d 의 울타리가 없음" % (kind, n))
            fence = lines[i]
            i += 1
            body = []
            while i < len(lines) and lines[i] != fence:
                body.append(lines[i])
                i += 1
            if i >= len(lines):
                raise Refused("보관 조각 %s%d 의 닫는 울타리가 없음" % (kind, n))
            i += 1
            if kind == "B":
                content = "".join(b + "\n" for b in body)
            else:
                content = "\n".join(body)
            blocks[-1].append((kind, n, heading, content))
            continue
        i += 1
    return blocks


DOC_MARK_A_RE = re.compile(r" \(보관 A([0-9]+)\)")
DOC_MARK_B_RE = re.compile(r"^\*\*보관\*\*: B([0-9]+)$", re.M)


def next_numbers(archive_text, doc_text=None):
    """Next A, B and C numbers: past every number the archive holds and every
    A or B marker the document already shows, so a marker the document took
    from another archive file is never written a second time."""
    nums = {"A": 0, "B": 0, "C": 0}
    if archive_text:
        for block in parse_archive(archive_text):
            for kind, n, _, _ in block:
                nums[kind] = max(nums[kind], n)
    if doc_text:
        for m in DOC_MARK_A_RE.finditer(doc_text):
            nums["A"] = max(nums["A"], int(m.group(1)))
        for m in DOC_MARK_B_RE.finditer(doc_text):
            nums["B"] = max(nums["B"], int(m.group(1)))
    return nums["A"] + 1, nums["B"] + 1, nums["C"] + 1


def fence_for(content):
    longest = max([len(m.group(0)) for m in BACKTICK_RUN_RE.finditer(content)] + [0])
    return "`" * max(3, longest + 1)


def render_block(pieces, writer, key):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    out = ["## 정리 %s — %s" % (stamp, writer), ""]
    for kind, n, heading, content in pieces:
        out.append("### %s%d" % (kind, n))
        if kind == "B":
            out.append("항목: %s" % heading)
        fence = fence_for(content)
        out.append(fence)
        if kind == "B":
            out.extend(content[:-1].split("\n") if content else [])
        else:
            out.append(content)
        out.append(fence)
        out.append("")
    return "\n".join(out) + "\n"


def new_archive_text(existing, pieces, writer, key):
    if existing:
        base = existing if existing.endswith("\n") else existing + "\n"
        return base + "\n" + render_block(pieces, writer, key)
    head = "# 설계 문서 보관 — %s\n%s\n\n" % (key, archive_head(key))
    return head + render_block(pieces, writer, key)


def atomic_write(path, data):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".doc-tidy.", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ------------------------------------------------------------- check

def restore(after_text, block):
    """Expand the A/B markers of one archive block in AFTER."""
    lines = split_lines(after_text)
    b_pieces = {n: content for kind, n, _, content in block if kind == "B"}
    a_pieces = {n: content for kind, n, _, content in block if kind == "A"}
    out = []
    for line in lines:
        m = re.match(r"^\*\*보관\*\*: B([0-9]+)$", line)
        if m and int(m.group(1)) in b_pieces:
            content = b_pieces.pop(int(m.group(1)))
            out.extend(content[:-1].split("\n") if content else [])
            continue
        out.append(line)
    text = join_lines(out)
    for n, frag in sorted(a_pieces.items()):
        mark = " (보관 A%d)" % n
        if text.count(mark) != 1:
            raise Refused("위치 표시 %s 가 정리 후 문서에 정확히 한 번 있지 않음" % mark.strip())
        text = text.replace(mark, frag, 1)
    if b_pieces:
        raise Refused("위치 표시가 없는 B 조각: %s" % ",".join("B%d" % n for n in sorted(b_pieces)))
    return text


def expected_before(before_text, block):
    c_lines = set(content for kind, _, _, content in block if kind == "C")
    if not c_lines:
        return before_text
    lines = split_lines(before_text)
    mask = fence_mask(lines)
    return join_lines([unmark_line(line) if (not mask[i] and line in c_lines) else line
                       for i, line in enumerate(lines)])


def check_texts(before_text, after_text, archive_text):
    if before_text == after_text:
        return None
    blocks = parse_archive(archive_text) if archive_text else []
    if not blocks:
        return "보관 파일에 블록이 없음"
    block = blocks[-1]
    try:
        restored = restore(after_text, block)
    except Refused as e:
        return str(e)
    want = expected_before(before_text, block)
    if restored != want:
        rb, wb = restored.encode("utf-8"), want.encode("utf-8")
        k = 0
        while k < min(len(rb), len(wb)) and rb[k] == wb[k]:
            k += 1
        return "되돌린 바이트열이 정리 전과 %d 바이트째에서 다름 (되돌림 %d, 정리 전 %d)" % (k, len(rb), len(wb))
    return None


# ------------------------------------------------------------- verbs

def piece_bytes(pieces, kind):
    return sum(len(c.encode("utf-8")) for k, _, _, c in pieces if k == kind)


def read_reviewed(args):
    return read_text(args.reviewed)[1] if args.reviewed else None


def cmd_plan(args):
    data, text = read_text(args.doc)
    new_text, pieces = transform_apply(text, None, 1, 1, read_reviewed(args))
    print("current=%d" % len(data))
    print("t1_count=%d" % sum(1 for p in pieces if p[0] == "A"))
    print("t1_bytes=%d" % piece_bytes(pieces, "A"))
    print("t3_count=%d" % sum(1 for p in pieces if p[0] == "B"))
    print("t3_bytes=%d" % piece_bytes(pieces, "B"))
    print("expected=%d" % len(new_text.encode("utf-8")))
    return 0


def checked_write_pair(args, pieces, text, new_text, existing):
    """Run the `check` comparison in memory and write only when it passes."""
    arch = new_archive_text(existing, pieces, args.writer, args.doc_key)
    why = check_texts(text, new_text, arch)
    if why:
        print("doc-tidy %s: 되돌림 검사 실패 — %s" % (args.verb, why), file=sys.stderr)
        return 1
    return write_pair(args, pieces, new_text, existing)


def write_pair(args, pieces, new_text, existing):
    arch = new_archive_text(existing, pieces, args.writer, args.doc_key)
    atomic_write(args.archive, arch.encode("utf-8"))
    try:
        atomic_write(args.doc, new_text.encode("utf-8"))
    except OSError as e:
        print("doc-tidy: 문서 교체 실패 — %s (보관 블록은 남김)" % e, file=sys.stderr)
        return 1
    return 0


def cmd_apply(args):
    _, text = read_text(args.doc)
    base = read_text(args.since)[1] if args.since else None
    existing = load_archive(args.archive, args.doc_key)
    na, nb, _ = next_numbers(existing, text)
    new_text, pieces = transform_apply(text, base, na, nb, read_reviewed(args))
    print("moved=%d" % len(pieces))
    if not pieces:
        return 0
    return checked_write_pair(args, pieces, text, new_text, existing)


def cmd_unmark(args):
    _, text = read_text(args.doc)
    _, base = read_text(args.since)
    existing = load_archive(args.archive, args.doc_key)
    _, _, nc = next_numbers(existing, text)
    new_text, pieces = transform_unmark(text, base, nc)
    print("unmarked=%d" % len(pieces))
    if not pieces:
        return 0
    return checked_write_pair(args, pieces, text, new_text, existing)


def cmd_check(args):
    _, before = read_text(args.before)
    _, after = read_text(args.after)
    archive = read_text(args.archive)[1] if os.path.exists(args.archive) else ""
    why = check_texts(before, after, archive)
    if why:
        print("doc-tidy check: %s" % why, file=sys.stderr)
        return 1
    print("check=ok")
    return 0


def cmd_tidy(args):
    data, text = read_text(args.doc)
    existing = load_archive(args.archive, args.doc_key)
    na, nb, _ = next_numbers(existing, text)
    reviewed = read_reviewed(args)
    est_text, _ = transform_apply(text, None, 1, 1, reviewed)
    expected = len(est_text.encode("utf-8"))
    print("current=%d" % len(data))
    print("expected=%d" % expected)
    if expected >= args.below:
        print("doc-tidy tidy: 예상 크기 %d 가 문턱 %d 이상" % (expected, args.below), file=sys.stderr)
        return 1
    new_text, pieces = transform_apply(text, None, na, nb, reviewed)
    if not pieces:
        print("doc-tidy tidy: 옮길 조각이 없음", file=sys.stderr)
        return 1
    new_bytes = new_text.encode("utf-8")
    if len(new_bytes) >= args.below:
        print("doc-tidy tidy: 정리 뒤 크기 %d 가 문턱 %d 이상" % (len(new_bytes), args.below),
              file=sys.stderr)
        return 1
    arch = new_archive_text(existing, pieces, args.writer, args.doc_key)
    why = check_texts(text, new_text, arch)
    if why:
        print("doc-tidy tidy: 되돌림 검사 실패 — %s" % why, file=sys.stderr)
        return 1
    rc = write_pair(args, pieces, new_text, existing)
    if rc == 0:
        print("after=%d" % len(new_bytes))
        print("pre_sha256=%s" % hashlib.sha256(data).hexdigest())
        print("post_sha256=%s" % hashlib.sha256(new_bytes).hexdigest())
    return rc


def main(argv):
    p = argparse.ArgumentParser(prog="doc-tidy.py")
    sub = p.add_subparsers(dest="verb", required=True)

    sp = sub.add_parser("plan")
    sp.add_argument("doc")
    sp.add_argument("--reviewed")

    for name in ("apply", "unmark", "tidy"):
        sp = sub.add_parser(name)
        sp.add_argument("doc")
        sp.add_argument("--archive", required=True)
        sp.add_argument("--doc-key", required=True)
        sp.add_argument("--writer", required=True)
        if name != "unmark":
            sp.add_argument("--reviewed")
        if name == "apply":
            sp.add_argument("--since")
        elif name == "unmark":
            sp.add_argument("--since", required=True)
        else:
            sp.add_argument("--below", required=True, type=int)

    sp = sub.add_parser("check")
    sp.add_argument("before")
    sp.add_argument("after")
    sp.add_argument("archive")

    args = p.parse_args(argv)
    handler = {"plan": cmd_plan, "apply": cmd_apply, "unmark": cmd_unmark,
               "check": cmd_check, "tidy": cmd_tidy}[args.verb]
    try:
        return handler(args)
    except Refused as e:
        print("doc-tidy %s: %s" % (args.verb, e), file=sys.stderr)
        return 1
    except (OSError, UnicodeDecodeError) as e:
        print("doc-tidy %s: %s" % (args.verb, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
