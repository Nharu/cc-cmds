"""dashboard_read.py — the dashboard's read-only model of every run on this host.

NOTHING HERE WRITES, AND NOTHING HERE CALLS THE GATE. Entering `gate.sh` with
any verb rewrites the run's `started-at`, settles lost dispatches as
`외부 종료` rows and starts a metrics round, so a viewer that called it would
change what it is looking at. Calling the shell predicates in `liveness.sh`
once per run is ruled out for a different reason: measured, it costs about a
tenth of a second per run, so a host with five hundred run directories would
need most of a minute per refresh.

THE PREDICATES ARE THEREFORE PORTED, ONE TO ONE. `cc_stage_is_live`,
`cc_live_stages`, `cc_run_state`, `cc_run_grade`, `cc_nonterminal_segments`,
`cc_segment_count`, `cc_open_approvals`, `cc_unresolved_blocked` with its
`cc__blocked_fold`, `cc_waiting_fresh_count` with the waiting-marker chain it
calls (`cc_waiting_is_member`, `cc_waiting_field`, `cc_rows_naming_lineage`,
`cc_waiting_age_base`, `cc_effective_stall`, `wake_epoch`, `platform_supported`),
`cc_shift_is_live`, `cc_run_ends_on_done`, `cc_run_end_settled`,
`cc_unanswered_halts` with its `cc__halt_answer_state`, `cc_stage_kind`,
`cc_display_tz_load` (`display-tz.sh`), `cc_ledger_growth_at` and `cc_mtime`
each have a function below that reads the
same bytes the same way, down to the greedy `sed` captures and the word
splitting of a `for` loop. That is deliberate: two implementations of one
predicate are only safe while something holds them together, and
`scripts/test-liveness-agreement.sh` is that something — it runs this port and
the shell functions over the same fixtures and fails on any disagreement. A
"cleaner" reading here is a disagreement there.

The one substitution is how a process is identified. The shell asks `kill -0`
and `ps -o lstart= -p` per pid; this module takes one `ps` table per scan and
answers both questions from it, with the same whitespace normalisation the
shell applies to a fingerprint.

Python 3.9 standard library only.
"""

import calendar
import json
import os
import re
import subprocess
import time

STALL_S = 180
ABANDON_S = 3600
WINDOW_S = 3 * 86400
TERMINAL_SEGMENT_STATES = "머지됨 완료 park"
LEDGER_H1 = ("# 파이프라인 런 보고서", "# 아침 보고서")
KEEP_SERIES = frozenset(
    ["segment", "승인", "blocked", "cycle", "stage-result", "cost", "교대 기동", "run", "종료 절",
     "handoff", "중단 답"]
)
HALT_READ_LIMIT = 16384
WAITING_TEXT_BYTES = 400

_ROW_HEAD = re.compile(r"^- `([^`]*)`")
_ISO = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2}))")
_HB_GROWTH = re.compile(r".*마지막성장=([0-9][0-9]*)")
_DIGITS = re.compile(r"[0-9]+")


def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")


def run_root():
    return os.path.join(state_home(), "cc-cmds", "run")


def iso_epoch(s):
    """An ISO stamp (`Z` or a `+HH:MM` offset) as epoch seconds, or None."""
    if not s:
        return None
    m = _ISO.search(s)
    if not m:
        return None
    v = m.group(1)
    try:
        if v.endswith("Z"):
            return calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ"))
        base = calendar.timegm(time.strptime(v[:19], "%Y-%m-%dT%H:%M:%S"))
        sign = 1 if v[19] == "+" else -1
        return base - sign * (int(v[20:22]) * 3600 + int(v[23:25]) * 60)
    except ValueError:
        return None


def read_text(path, limit=None):
    try:
        with open(path, "rb") as f:
            data = f.read() if limit is None else f.read(limit)
    except OSError:
        return None
    return data.decode("utf-8", "replace")


def cmd_subst(path):
    """`$(cat path 2>/dev/null)` — the file with its trailing newlines removed."""
    t = read_text(path)
    return "" if t is None else t.rstrip("\n")


# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

class ProcTable:
    """One `ps` reading, answering `kill -0` and the fingerprint for every pid.

    `-axo` is the spelling the shell side uses on macOS. A `ps` that rejects it
    is asked again with `-A`, which is the same selection, so the table is the
    same set of processes on either host.
    """

    def __init__(self):
        self.rows = None
        self._wake = None
        env = dict(os.environ)
        env["LC_ALL"] = "C"
        for argv in (["ps", "-axo", "pid=,pgid=,lstart="], ["ps", "-A", "-o", "pid=,pgid=,lstart="]):
            try:
                r = subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, timeout=10)
            except (OSError, subprocess.SubprocessError):
                continue
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rows = {}
            for raw in r.stdout.decode("utf-8", "replace").splitlines():
                parts = raw.split(None, 2)
                if len(parts) < 3 or not parts[0].isdigit():
                    continue
                rows[int(parts[0])] = (parts[1], " ".join(parts[2].split()))
            self.rows = rows
            break

    def exists(self, pid):
        if self.rows is not None:
            return pid in self.rows
        try:
            os.kill(pid, 0)
        except (OSError, OverflowError):
            return False
        return True

    def fingerprint(self, pid):
        if self.rows is None:
            return ""
        row = self.rows.get(pid)
        return row[1] if row else ""

    def pgid(self, pid):
        if self.rows is None:
            return ""
        row = self.rows.get(pid)
        return row[0] if row else ""

    def wake(self):
        """`wake_epoch`, read once per scan as the shell reads it once per walk."""
        if self._wake is None:
            self._wake = wake_epoch()
        return self._wake


def _pid_of(text):
    """`kill -0 "$pid"` accepts a plain decimal and nothing padded."""
    if not text or not _DIGITS.fullmatch(text):
        return None
    try:
        return int(text)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# The ported predicates (liveness.sh)
# ---------------------------------------------------------------------------

def stage_is_live(run_dir, seg, procs):
    """cc_stage_is_live."""
    if not run_dir or not seg:
        return False
    f = os.path.join(run_dir, seg + ".pid")
    if not os.path.isfile(f):
        return False
    start_f = os.path.join(run_dir, seg + ".start")
    pgid_f = os.path.join(run_dir, seg + ".pgid")
    if not (os.path.isfile(start_f) or os.path.isfile(pgid_f)):
        return False
    pid = _pid_of(cmd_subst(f))
    if pid is None or not procs.exists(pid):
        return False
    rec = cmd_subst(start_f)
    if rec:
        return rec == procs.fingerprint(pid)
    rec = "".join(cmd_subst(pgid_f).split())
    if not rec:
        return False
    now = procs.pgid(pid)
    return bool(now) and rec == now


def pid_files(run_dir):
    try:
        names = os.listdir(run_dir)
    except OSError:
        return []
    return sorted(n for n in names if n.endswith(".pid") and not n.startswith(".")
                  and os.path.isfile(os.path.join(run_dir, n)))


def live_stages(run_dir, procs):
    """cc_live_stages, returning the names — its length is the census."""
    if not run_dir:
        return []
    return [n[:-4] for n in pid_files(run_dir) if stage_is_live(run_dir, n[:-4], procs)]


def _rows(lines, series):
    head = "- `%s`" % series
    return [ln for ln in lines if ln.startswith(head)]


def _field_values(line, key):
    """`tr '|' '\\n' | sed -n 's/^ *KEY=//p' | sed 's/[[:space:]]*$//'`."""
    out = []
    pat = re.compile(r"^ *" + re.escape(key) + "=")
    for part in line.split("|"):
        m = pat.match(part)
        if m:
            out.append(part[m.end():].rstrip())
    return out


def _field_last(line, key):
    vals = _field_values(line, key)
    return vals[-1] if vals else ""


def _field_whole_values(line, key):
    """awk `split($0, f, / \\| /)`, then every piece from the second on that
    starts with `KEY=`, its value with trailing blanks dropped."""
    out = []
    head = key + "="
    for part in line.split(" | ")[1:]:
        if part.startswith(head):
            out.append(part[len(head):].rstrip(_BLANKS))
    return out


def _field_whole_is(line, key, value):
    """Whether any `KEY=` field of the line is exactly `value`."""
    return value in _field_whole_values(line, key)


def _greedy_id(line):
    """`sed -n 's/.*id=\\([^|]*\\).*/\\1/p'` — the LAST `id=` on the line."""
    i = line.rfind("id=")
    if i < 0:
        return None
    return line[i + 3:].split("|", 1)[0].rstrip()


def segment_ids(lines):
    vals = set()
    for ln in _rows(lines, "segment"):
        v = _greedy_id(ln)
        if v is not None:
            vals.add(v)
    return vals


def segment_count(lines):
    """cc_segment_count."""
    return len([v for v in segment_ids(lines) if v])


def _loop_words(values):
    """`for w in $(… | sort -u)` — unique lines, then word splitting.

    A word that occurs on two distinct lines is visited twice, as the shell
    loop visits it twice; collapsing to a set here would count it once.
    """
    out = []
    for v in sorted(values):
        out.extend(v.split())
    return out


def nonterminal_segments(lines):
    """cc_nonterminal_segments, returning the ids — its length is the count."""
    seg_rows = _rows(lines, "segment")
    out = []
    for sid in _loop_words(segment_ids(lines)):
        last = None
        needle = "id=%s " % sid
        for ln in seg_rows:
            if needle in ln:
                last = ln
        st = _field_last(last, "상태") if last is not None else ""
        ap = _field_last(last, "적용") if last is not None else ""
        if st == "머지됨" and ap == "대기":
            out.append(sid)
            continue
        if (" %s " % st) not in (" %s " % TERMINAL_SEGMENT_STATES):
            out.append(sid)
    return out


def open_approval_rows(lines):
    """cc_open_approvals' walk — (승인 id, its last row) per open approval, a
    word the loop visits twice listed twice, as the shell counts it twice."""
    rows = _rows(lines, "승인")
    values = set()
    for ln in rows:
        values.update(_field_values(ln, "승인 id"))
    out = []
    for aid in _loop_words(values):
        last = None
        needle = "| 승인 id=%s |" % aid
        for ln in rows:
            if needle in ln:
                last = ln
        if last is not None and _field_last(last, "상태") == "대기":
            out.append((aid, last))
    return out


def open_approvals(lines):
    """cc_open_approvals."""
    return len(open_approval_rows(lines))


def _halt_answer_state(numbered, tail):
    """cc__halt_answer_state over (line number, row) pairs in ledger order."""
    last = None
    stamped = set()
    for no, ln in numbered:
        if ln.startswith("- `중단 답` | "):
            for v in _field_whole_values(ln, "중단 기록"):
                if v.endswith(tail):
                    last = no
        if ln.startswith("- `blocked` | "):
            stamped.update(_field_whole_values(ln, "막힌 답 줄"))
    if last is None:
        return "없음"
    return "되돌림" if str(last) in stamped else "답함"


def unanswered_halt_records(run_dir, numbered):
    """cc_unanswered_halts — (path, `없음` or `되돌림`) per record still waiting.

    `numbered` is None for an empty ledger argument: no `중단 답` is looked
    for and every record counts.
    """
    if run_dir.endswith("/"):
        run_dir = run_dir[:-1]
    if not run_dir or not os.path.isdir(os.path.join(run_dir, "halt")):
        return []
    leaf = run_dir.rsplit("/", 1)[-1]
    out = []
    for sub in ("halt", "halt/shift"):
        d = os.path.join(run_dir, sub)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if name.startswith(".") or not name.endswith(".md") or name.endswith(".answer.md"):
                continue
            f = os.path.join(d, name)
            if not os.path.isfile(f):
                continue
            state = "없음"
            if numbered is not None:
                state = _halt_answer_state(numbered, "/%s/%s/%s" % (leaf, sub, name))
                if state == "답함":
                    continue
            out.append((f, state))
    return out


_HALT_FIELD = re.compile(r"^\*\*[^*][^*]*\*\*:")
_HALT_QUESTION = "**질문 문면**:"


def halt_record_fields(text):
    """The record's `**스킬**`·`**스텝**`·`**분류**`·`**추천**` lines and its
    `**질문 문면**`, read as the gate's `gate_halt_record_question` reads it."""
    out = {"skill": None, "step": None, "class": None, "recommend": None}
    heads = {"**스킬**:": "skill", "**스텝**:": "step", "**분류**:": "class", "**추천**:": "recommend"}
    q = done = False
    s = ""
    for ln in (text or "").split("\n"):
        for head, key in heads.items():
            if out[key] is None and ln.startswith(head):
                out[key] = ln[len(head):].strip()
        if not q and ln.startswith(_HALT_QUESTION):
            q = True
            s = ln[len(_HALT_QUESTION):]
            continue
        if q and (_HALT_FIELD.match(ln) or ln.startswith("<!-- /cc-pipeline-halt")):
            q = False
            done = True
        if q and not done:
            s = s + " " + ln
    s = re.sub(r"[ \t\r]+", " ", s)
    if s.startswith(" "):
        s = s[1:]
    if s.endswith(" "):
        s = s[:-1]
    out["question"] = s
    return out


def stage_kind(run_dir, lines, seg):
    """cc_stage_kind — the `.kind` file, else the last `stage-result` naming the
    segment as a whole field; None for neither."""
    if not seg:
        return None
    if run_dir:
        f = os.path.join(run_dir, seg + ".kind")
        if os.path.isfile(f):
            k = _strip_blanks(read_text(f) or "")
            if k:
                return k
    last = None
    for ln in _rows(lines, "stage-result"):
        hit = False
        k = ""
        for part in ln.split("|")[1:]:
            part = part.strip(" \t")
            if part == "세그먼트=" + seg:
                hit = True
            elif part.startswith("종류="):
                k = part[len("종류="):]
        if hit:
            last = k
    return last or None


def _awk_fld(line, name):
    """The fold's awk `fld`: the last `|` piece, from the second on, that starts
    with `name=` once its leading blanks are gone, trailing blanks dropped."""
    v = ""
    head = name + "="
    for s in line.split("|")[1:]:
        s = s.lstrip(" \t")
        if s.startswith(head):
            v = s[len(head):].rstrip(" \t")
    return v


_LINEAGE_B = re.compile(r"계보=B:([^ |#]+#[0-9]+)")


def _lineage_key(lin):
    """`B:<키>#<N>` as (키, N): the awk's two `sub`s and its `+ 0`."""
    k = re.sub(r"#[0-9]+$", "", lin)
    n = re.sub(r"^.*#", "", lin)
    m = re.match(r"[0-9]+", n)
    return k, int(m.group(0)) if m else 0


def _blocked_fold(lines):
    """cc__blocked_fold — (사유, 원인, 스코프, 앵커 세그먼트) per unresolved block
    that holds the whole run, in the byte order `LC_ALL=C sort` gives.

    `lines` must be every ledger line that carries a `계보=B:` lineage, in file
    order, beside the `segment` and `blocked` rows: a step cone is released by a
    later attempt's lineage on any row family.
    """
    seg = set()
    blocks = []
    lins = []
    for i, ln in enumerate(lines):
        lins.append(_LINEAGE_B.findall(ln))
        if ln.startswith("- `segment`"):
            sid = _awk_fld(ln, "id")
            if sid != "":
                seg.add(sid)
            continue
        if ln.startswith("- `blocked`"):
            blocks.append((i, _awk_fld(ln, "스코프"), _awk_fld(ln, "사유"),
                           _awk_fld(ln, "앵커 세그먼트"), _awk_fld(ln, "원인")))
    last = {}
    for i, scope, why, anchor, cause in blocks:
        if why == "":
            continue
        if scope == "run":
            step = False
        elif (scope == "cone" and anchor != "" and anchor not in seg
              and not anchor.startswith("clause-")):
            # A `clause-<id>` anchor is a termination clause's evidence
            # request: it holds that clause alone, not the run.
            step = True
        else:
            continue
        last[why] = (i, cause, step, scope, anchor)
    out = []
    for why, (i, cause, step, scope, anchor) in last.items():
        if cause == "해소":
            continue
        if step and lins[i]:
            k, nn = _lineage_key(lins[i][0])
            released = False
            for later in lins[i + 1:]:
                for lin in later:
                    lk, ln_ = _lineage_key(lin)
                    if lk == k and ln_ > nn:
                        released = True
                        break
                if released:
                    break
            if released:
                continue
        out.append((why, cause, scope, anchor))
    out.sort(key=lambda t: "\t".join(t).encode("utf-8"))
    return out


def unresolved_blocked(lines):
    """cc_unresolved_blocked — (원인, 사유) per unresolved block holding the run."""
    return [(cause, why) for why, cause, _scope, _anchor in _blocked_fold(lines)]


def mtime_s(path):
    """cc_mtime — whole epoch seconds, or None."""
    try:
        if not os.path.isfile(path):
            return None
        return int(os.stat(path).st_mtime // 1)
    except OSError:
        return None


def heartbeat_growth(run_dir):
    """The `마지막성장` field: (value or None, whether the file was there)."""
    hb = os.path.join(run_dir, "watch.heartbeat")
    if not os.path.isfile(hb):
        return None, False
    text = read_text(hb)
    v = None
    for ln in (text or "").split("\n"):
        m = _HB_GROWTH.match(ln)
        if m:
            v = int(m.group(1))
    return v, True


def ledger_growth_at(run_dir, ledger_path, hb_value=None):
    """cc_ledger_growth_at. `hb_value` lets a caller hand in a remembered field."""
    if not run_dir:
        return None
    v, _present = heartbeat_growth(run_dir) if hb_value is None else (hb_value, True)
    if v is not None:
        return v
    if not ledger_path:
        return None
    return mtime_s(ledger_path)


def shift_is_live(run_dir, procs):
    """cc_shift_is_live — pid on line 1, its fingerprint on line 2, both required."""
    f = os.path.join(run_dir, "shift.live")
    if not os.path.isfile(f):
        return False
    t = read_text(f)
    rows = (t or "").split("\n")
    pid_text = "".join(rows[0].split()) if rows else ""
    rec = rows[1] if len(rows) > 1 else ""
    if not pid_text or not rec:
        return False
    pid = _pid_of(pid_text)
    if pid is None or not procs.exists(pid):
        return False
    return rec == procs.fingerprint(pid)


def run_ends_on_done(run_dir):
    """cc_run_ends_on_done."""
    return os.path.exists(os.path.join(run_dir, "ends-on-done"))


def run_end_settled(run_dir, procs):
    """cc_run_end_settled — `done` exists and no shift is still settling it."""
    if not os.path.isfile(os.path.join(run_dir, "done")):
        return False
    if not run_ends_on_done(run_dir):
        return True
    return not shift_is_live(run_dir, procs)


GRADES = {"도는중": 1, "승인대기": 2, "진행중": 3, "정산중": 3, "정지경고": 4, "종단": 5, "버려짐": 6}


def run_grade(token):
    """cc_run_grade."""
    return GRADES.get(token, 9)


# ---------------------------------------------------------------------------
# Stages waiting for an account (liveness.sh, the waiting-marker block)
# ---------------------------------------------------------------------------

_BLANKS = " \t\n\v\f\r"
_STALL_DECL = re.compile(r"(?:^|[;" + _BLANKS + r"])STALL=[0-9]+", re.M)


def _strip_blanks(s):
    """`tr -d '[:space:]'`."""
    return "".join(ch for ch in s if ch not in _BLANKS)


def _sed_line(path, n):
    """`sed -n '<n>p' path`, as `$(…)` reads it."""
    t = read_text(path)
    if t is None:
        return ""
    rows = t.split("\n")
    if rows and rows[-1] == "":
        rows.pop()
    return rows[n - 1] if len(rows) >= n else ""


def platform_supported():
    """`platform_supported` — the host seam, then `uname -s`."""
    host = os.environ.get("ORCH_HOST_OS") or os.environ.get("CC_CMDS_ORCH_HOST_OS")
    if not host:
        try:
            host = os.uname().sysname
        except AttributeError:
            host = ""
    return host == "Darwin"


def wake_epoch():
    """`wake_epoch` — the field two after `sec` in `sysctl -n kern.waketime`, or ""."""
    if not platform_supported():
        return ""
    try:
        r = subprocess.run(["sysctl", "-n", "kern.waketime"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    for ln in r.stdout.decode("utf-8", "replace").split("\n"):
        f = re.split(r"[ ,]+", ln)
        for i, w in enumerate(f):
            if w == "sec":
                return f[i + 2] if i + 2 < len(f) else ""
    return ""


def effective_stall(run_dir, procs):
    """cc_effective_stall — the live watcher's threshold, else the watcher's one
    default declaration beside this module, else None."""
    f = os.path.join(run_dir, "watch.stall") if run_dir else ""
    if run_dir and os.path.isfile(f):
        v = _strip_blanks(_sed_line(f, 1))
        pid_text = _strip_blanks(_sed_line(f, 2))
        rec = _sed_line(f, 3)
        if _DIGITS.fullmatch(v) and _DIGITS.fullmatch(pid_text):
            pid = int(pid_text)
            if int(v) > 0 and rec and procs.exists(pid) and rec == procs.fingerprint(pid):
                return int(v)
    t = read_text(os.path.join(os.path.dirname(os.path.abspath(__file__)), "watch.sh"))
    decl = _STALL_DECL.findall(t or "")
    if len(decl) != 1:
        return None
    v = int(decl[0].rsplit("=", 1)[1])
    return v if v > 0 else None


def waiting_field(path, key):
    """cc_waiting_field — the last `key=` line's value."""
    t = read_text(path)
    if t is None:
        return ""
    head = key + "="
    v = ""
    for ln in t.split("\n"):
        if ln.startswith(head):
            v = ln[len(head):]
    return v


def rows_naming_lineage(rows, lin):
    """cc_rows_naming_lineage — the rows carrying `계보=<lin>` as a whole value."""
    pat = "계보=" + lin
    out = []
    for row in rows:
        s = row
        while True:
            i = s.find(pat)
            if i < 0:
                break
            c = s[i + len(pat):i + len(pat) + 1]
            if not re.match(r"[0-9A-Za-z_.#:-]", c):
                out.append(row)
                break
            s = s[i + len(pat):]
    return out


def waiting_is_member(run_dir, lines, ledger_path, key, procs):
    """cc_waiting_is_member — the holder still lives, no live stage holds the
    key, and the attempt has neither a `stage-result` nor a `blocked` row."""
    if not run_dir or not key:
        return False
    f = os.path.join(run_dir, key + ".waiting")
    if not os.path.isfile(f):
        return False
    pid_text = _strip_blanks(waiting_field(f, "보유자"))
    fp = waiting_field(f, "지문")
    if not _DIGITS.fullmatch(pid_text) or not fp:
        return False
    pid = int(pid_text)
    if not procs.exists(pid) or fp != procs.fingerprint(pid):
        return False
    if stage_is_live(run_dir, key, procs):
        return False
    if not ledger_path or not os.path.isfile(ledger_path):
        return True
    att = _strip_blanks(waiting_field(f, "시도"))
    lin = waiting_field(f, "계보")
    if att:
        seg_k, stage_k, att_k = "세그먼트=%s " % key, "스테이지=%s " % key, "실행 버전=%s " % att
        for ln in _rows(lines, "stage-result"):
            if (seg_k in ln or stage_k in ln) and att_k in ln:
                return False
    if lin and rows_naming_lineage(_rows(lines, "blocked"), lin):
        return False
    return True


def waiting_age_base(refreshed, wake):
    """cc_waiting_age_base — the later of refresh and wake, 0 for a non-number."""
    r = int(refreshed) if _DIGITS.fullmatch(refreshed or "") else 0
    w = int(wake) if _DIGITS.fullmatch(wake or "") else 0
    return w if w > r else r


def waiting_fresh_count(run_dir, lines, ledger_path, procs, now=None, stall=None):
    """cc_waiting_fresh_count — members whose later of refresh and wake is
    younger than the effective stall threshold."""
    return len(waiting_fresh(run_dir, lines, ledger_path, procs, now=now, stall=stall))


def waiting_fresh(run_dir, lines, ledger_path, procs, now=None, stall=None):
    """The fresh members `waiting_fresh_count` counts, as (file name, the later
    of refresh and wake) in name order."""
    if not run_dir:
        return []
    try:
        names = sorted(os.listdir(run_dir))
    except OSError:
        return []
    out = []
    first = True
    wake = ""
    for name in names:
        if not name.endswith(".waiting") or name.startswith("."):
            continue
        f = os.path.join(run_dir, name)
        if not os.path.isfile(f):
            continue
        key = name[:-len(".waiting")]
        if not waiting_is_member(run_dir, lines, ledger_path, key, procs):
            continue
        if first:
            first = False
            if now is None:
                now = int(time.time())
            wake = procs.wake()
            if stall is None:
                stall = effective_stall(run_dir, procs)
        base = waiting_age_base(_strip_blanks(waiting_field(f, "갱신")), wake)
        if stall is not None and base > 0 and now - base < stall:
            out.append((name, base))
    return out


def run_state(run_dir, lines, ledger_path, procs, stall=STALL_S, abandon=ABANDON_S,
              now=None, growth=None, live=None):
    """cc_run_state over a ledger already read into `lines`."""
    if live is None:
        live = live_stages(run_dir, procs)
    # A fresh waiter is folded into the live count, as the shell folds it; the
    # names list stays the running stages, which is what the detail shows.
    if len(live) > 0 or waiting_fresh_count(run_dir, lines, ledger_path, procs, now=now) > 0:
        return "도는중"
    blocked_n = len(unresolved_blocked(lines))
    pend = open_approvals(lines)
    nonterm = len(nonterminal_segments(lines))
    n_seg = segment_count(lines)
    settle = False
    if blocked_n == 0:
        if os.path.isfile(os.path.join(run_dir, "done")):
            return "종단" if run_end_settled(run_dir, procs) else "정산중"
        if pend == 0 and nonterm == 0 and n_seg >= 1:
            if run_ends_on_done(run_dir):
                settle = True
            else:
                return "종단"
    if pend > 0:
        return "승인대기"
    grew = growth if growth is not None else ledger_growth_at(run_dir, ledger_path)
    if grew is None:
        return "버려짐"
    if now is None:
        now = int(time.time())
    idle = now - grew
    if idle < 0:
        idle = 0
    if idle >= abandon:
        return "버려짐"
    if idle >= stall:
        return "정지경고"
    if settle:
        return "정산중"
    return "진행중"


def read_ledger_lines(path):
    if not path:
        return []
    t = read_text(path)
    if t is None:
        return []
    lines = t.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


# ---------------------------------------------------------------------------
# Incremental ledger reading
# ---------------------------------------------------------------------------

def split_fields(line):
    """A row's fields as a dict, first value winning, `|` inside backticks kept."""
    parts, buf, in_code = [], [], False
    for ch in line:
        if ch == "`":
            in_code = not in_code
            buf.append(ch)
        elif ch == "|" and not in_code:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    parts.append("".join(buf))
    out = {}
    for p in parts[1:]:
        p = p.strip()
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        k = k.strip()
        if k and k not in out:
            v = v.strip()
            if len(v) >= 2 and v[0] == "`" and v[-1] == "`":
                v = v.strip("`")
            out[k] = v
    return out


class Ledger:
    """An append-only ledger read by offset.

    Remembered by (dev, inode, offset). Bytes after the last newline are left
    for the next read, so a row being written is never parsed in half. A
    shorter file or a different inode starts over. Only the row families the
    dashboard reads are kept, and beside them every line carrying a `계보=B:`
    lineage; `자율 승인`, which is most of every ledger, is otherwise passed over.

    Every kept row's ledger line number (the first line is 1, as awk's `NR`)
    is held in `linenos`, beside `rows` and as long. The count stops where the
    read stops, at the last newline, so a row being written is numbered when
    it is read. A `자율 승인` row is a judgment only when its head says so and
    its `kind` field is exactly `judgment`; those go to `judged` as (line
    number, row), and a `자율 승인` line kept for its lineage is not one.
    """

    def __init__(self, path):
        self.path = path
        self.ident = None
        self.offset = 0
        self.size = None
        self.mtime_ns = None
        self.mtime = None
        self.missing = True
        self._reset()

    def _reset(self):
        self.offset = 0
        self.rows = []
        self.linenos = []
        self.judged = []
        self.nlines = 0
        self.first_line = None
        self.first_time = None

    def refresh(self):
        try:
            st = os.stat(self.path)
        except OSError:
            self.missing = True
            self.ident = None
            self.size = self.mtime_ns = self.mtime = None
            self._reset()
            return
        self.missing = False
        ident = (st.st_dev, st.st_ino)
        if ident != self.ident or st.st_size < self.offset:
            self.ident = ident
            self._reset()
        self.size = st.st_size
        self.mtime_ns = st.st_mtime_ns
        self.mtime = int(st.st_mtime // 1)
        if st.st_size <= self.offset:
            return
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read(st.st_size - self.offset)
        except OSError:
            return
        cut = data.rfind(b"\n")
        if cut < 0:
            return
        self.offset += cut + 1
        for raw in data[:cut].split(b"\n"):
            self.nlines += 1
            self._ingest(raw.decode("utf-8", "replace"), self.nlines)

    def _ingest(self, line, no):
        if self.first_line is None:
            self.first_line = line
        m = _ROW_HEAD.match(line)
        if m and self.first_time is None:
            t = iso_epoch(line)
            if t is not None:
                self.first_time = t
        if (m and m.group(1) == "자율 승인" and "| kind=judgment |" in line
                and _field_whole_is(line, "kind", "judgment")):
            self.judged.append((no, line))
        if m and m.group(1) in KEEP_SERIES:
            self.rows.append((m.group(1), line))
            self.linenos.append(no)
        elif "계보=B:" in line:
            # The blocked fold releases a step cone on a later attempt's lineage,
            # which any line may carry, so those lines are kept in file order.
            self.rows.append((m.group(1) if m else None, line))
            self.linenos.append(no)

    def lines(self):
        return [ln for _s, ln in self.rows]

    def numbered(self, name=None):
        """(line number, row) per kept row, or per row of one family."""
        return [(no, ln) for no, (s, ln) in zip(self.linenos, self.rows) if name is None or s == name]

    def series(self, name):
        return [ln for s, ln in self.rows if s == name]


def ledger_h1(path):
    t = read_text(path, 512)
    if not t:
        return None
    return t.split("\n", 1)[0]


def is_ledger_file(path):
    name = os.path.basename(path)
    if not name.endswith(".md"):
        return False
    if "." in name[:-3]:
        return False
    h1 = ledger_h1(path) or ""
    return any(h1.startswith(h) for h in LEDGER_H1)


def base_of(ledger_path):
    marker = "/docs/pipeline-run/"
    i = ledger_path.find(marker)
    if i < 0:
        return None
    return ledger_path[:i]


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def parse_manifest(path):
    text = read_text(path)
    if text is None:
        return None
    out = {"steps": [], "goal": None, "deadline": None, "ceiling": None, "clauses": [], "anchor": None,
           "targets": []}
    section = None
    in_json = False
    buf = []
    for ln in text.split("\n"):
        if ln.startswith("## "):
            section = ln[3:].strip()
            continue
        if section == "실행 계획":
            if ln.startswith("```json"):
                in_json = True
                buf = []
                continue
            if in_json and ln.startswith("```"):
                in_json = False
                try:
                    plan = json.loads("\n".join(buf))
                    for s in plan.get("steps") or []:
                        out["steps"].append({
                            "id": str(s.get("id", "")),
                            "skill": str(s.get("skill", "")),
                            "depends_on": [str(d) for d in (s.get("depends_on") or [])],
                        })
                except (ValueError, AttributeError, TypeError):
                    pass
                continue
            if in_json:
                buf.append(ln)
        if ln.startswith("**앵커 키**:"):
            out["anchor"] = ln.split(":", 1)[1].strip()
        elif ln.startswith("**종료 지점**:"):
            out["goal"] = ln.split(":", 1)[1].strip()
        elif ln.startswith("**벽시계 마감**:"):
            out["deadline"] = ln.split(":", 1)[1].strip()
        elif ln.startswith("**비용 천장**:"):
            out["ceiling"] = ln.split(":", 1)[1].strip()
        elif ln.startswith("- `종료 절`"):
            f = split_fields(ln)
            if f.get("id"):
                out["clauses"].append({"id": f["id"], "text": f.get("문면", "")})
        elif ln.startswith("- `target`"):
            f = split_fields(ln)
            out["targets"].append({"alias": f.get("별칭"), "slug": f.get("원격 슬러그")})
    return out


_SLUG = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")


def run_prs(segment_rows, manifest):
    """`{seg, number, url}` per `PR=<n>` a `segment` row carries, in ledger order.

    The slug is the row's `레포=`, else the one target's `원격 슬러그`; one that
    cannot be settled, or is not `<owner>/<repo>`, leaves `url` null.
    """
    targets = (manifest or {}).get("targets") or []
    single = targets[0].get("slug") if len(targets) == 1 else None
    out = []
    seen = set()
    for ln in segment_rows:
        f = split_fields(ln)
        sid, n = f.get("id"), f.get("PR")
        if not sid or not n or not _DIGITS.fullmatch(n) or (sid, n) in seen:
            continue
        seen.add((sid, n))
        slug = f.get("레포") or single
        url = "https://github.com/%s/pull/%s" % (slug, n) if slug and _SLUG.fullmatch(slug) else None
        out.append({"seg": sid, "number": int(n), "url": url})
    return out


# ---------------------------------------------------------------------------
# The display time zone (display-tz.sh)
# ---------------------------------------------------------------------------

_TZ_UTC = re.compile(r"[Uu][Tt][Cc]|[Zz]")
_TZ_OFFSET = re.compile(r"[+-][0-9][0-9]:[0-9][0-9]")


def display_tz(value=None):
    """cc_display_tz_load — (offset seconds, label) for `CC_CMDS_AUTOPILOT_TZ`,
    read verbatim. `[0-9]` and `fullmatch` keep to the shell's `case`: ASCII
    digits only, and the whole string, a trailing newline included."""
    v = os.environ.get("CC_CMDS_AUTOPILOT_TZ", "") if value is None else value
    if _TZ_UTC.fullmatch(v):
        return 0, "UTC"
    if not _TZ_OFFSET.fullmatch(v):
        return 32400, "KST"
    hh, mm = int(v[1:3]), int(v[4:6])
    if mm > 59:
        return 32400, "KST"
    off = hh * 3600 + mm * 60
    if v[0] == "-":
        off = -off
    if off < -43200 or off > 50400:
        return 32400, "KST"
    if off == 32400:
        return off, "KST"
    if off == 0:
        return off, "UTC"
    return off, "UTC" + v


def day_key(epoch, off):
    """`YYYY-MM-DD` of an instant in the display zone."""
    return time.strftime("%Y-%m-%d", time.gmtime(epoch + off))


def day_start(epoch, off):
    """The display zone's midnight on or before an instant, as epoch seconds."""
    return epoch - (epoch + off) % 86400


def ceiling_usd(ceiling):
    if not ceiling:
        return None
    m = re.search(r"[0-9]+(?:\.[0-9]+)?", ceiling)
    return float(m.group(0)) if m else None


# ---------------------------------------------------------------------------
# Stage logs
# ---------------------------------------------------------------------------

_SUP_END = "스테이지 종단 — "
_SUP_REATTACH = "스테이지 재부착 — "


def read_sup(path):
    """First-line start, the stage's terminal line, and re-attach times."""
    text = read_text(path)
    if text is None:
        return None
    lines = text.split("\n")
    start = iso_epoch(lines[0][:25]) if lines and lines[0] else None
    end = None
    reattach = []
    for ln in lines:
        if _SUP_END in ln and end is None:
            tok = ln.split(_SUP_END, 1)[1].split(" ", 1)[0]
            if "#" not in tok:
                end = iso_epoch(ln[:25])
        elif _SUP_REATTACH in ln:
            t = iso_epoch(ln[:25])
            if t is not None:
                reattach.append(t)
    return {"start": start, "end": end, "reattach": reattach}


def result_duration_ms(path):
    """`duration_ms` of the stream's last `"type":"result"` line, read from the end."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            back = min(size, 1 << 20)
            f.seek(size - back)
            tail = f.read(back)
    except OSError:
        return None
    for raw in reversed(tail.split(b"\n")):
        if b'"type":"result"' not in raw and b'"type": "result"' not in raw:
            continue
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        v = obj.get("duration_ms") if isinstance(obj, dict) else None
        return v if isinstance(v, (int, float)) else None
    return None


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

class RunSource:
    """One run as found on disk: a run directory with a ledger, or a ledger alone."""

    def __init__(self, run_id, run_dir, ledger_path):
        self.id = run_id
        self.run_dir = run_dir
        self.ledger_path = ledger_path
        self.base = base_of(ledger_path) if ledger_path else None
        self.ledger = Ledger(ledger_path) if ledger_path else None
        self.hb_value = None
        self.frozen_key = None
        self.frozen = None
        # (관측 시각, 누적 usd) per `cost` row, kept beside a frozen evaluation:
        # the day's share is taken from it at every request.
        self.cost_points = []


def stamp_key(src):
    led = src.ledger
    rd = src.run_dir

    def mt(p):
        try:
            return os.stat(p).st_mtime_ns
        except OSError:
            return None

    return (
        led.size if led else None,
        led.mtime_ns if led else None,
        os.path.isfile(os.path.join(rd, "done")) if rd else None,
        mt(os.path.join(rd, "watch.heartbeat")) if rd else None,
        mt(os.path.join(rd, "log")) if rd else None,
        # A marker-bearing run reads 종단 only once its shift is gone, and the
        # shift ending changes no file — so 정산중 is never frozen, and these
        # two make a frozen 종단 re-evaluate when a marker or a shift appears.
        os.path.exists(os.path.join(rd, "ends-on-done")) if rd else None,
        mt(os.path.join(rd, "shift.live")) if rd else None,
        # A waiter appearing or refreshing can turn a frozen 종단 back into 도는중.
        waiting_stamp(rd) if rd else None,
        # A halt record or its answer attachment appearing changes `waiting`.
        halt_stamp(rd) if rd else None,
    )


def halt_stamp(run_dir):
    out = []
    for sub in ("halt", "halt/shift"):
        d = os.path.join(run_dir, sub)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            try:
                out.append((sub, n, os.stat(os.path.join(d, n)).st_mtime_ns))
            except OSError:
                pass
    return tuple(out)


_ACTION_TAIL = ("대상", "절단점", "막는 세그먼트")


def approval_text(row):
    """The approval's question. An action approval's question is one fixed
    sentence, so its target, cut point and blocked segment follow it."""
    f = split_fields(row)
    text = f.get("질문 문면", "")
    if f.get("절단점") in ("판단", "경계"):
        return text
    tail = ["%s %s" % (k, f[k]) for k in _ACTION_TAIL if f.get(k) and f[k] != "-"]
    return text + (" — " + " · ".join(tail) if tail else "")


def waiting_items(approvals, halts, waiters):
    """`waiting`: open approvals, then unanswered halt records, then fresh waiters."""
    out = []
    seen = set()
    for aid, row in approvals:
        if aid in seen:
            continue
        seen.add(aid)
        out.append({"kind": "승인", "text": approval_text(row), "ref": aid,
                    "since": iso_epoch(split_fields(row).get("발행 시각")), "returned": False})
    for path, state in halts:
        rec = halt_record_fields(read_text(path, HALT_READ_LIMIT))
        out.append({"kind": "중단 기록", "text": rec["question"], "ref": path, "since": mtime_s(path),
                    "returned": state == "되돌림", "skill": rec["skill"], "step": rec["step"],
                    "class": rec["class"], "recommend": rec["recommend"]})
    for name, base in waiters:
        out.append({"kind": "사용량 한도", "text": "사용량 한도 대기", "ref": name, "since": base,
                    "returned": False})
    return out


def clip_bytes(text, n=WAITING_TEXT_BYTES):
    """The text cut at `n` UTF-8 bytes, never inside a character."""
    b = (text or "").encode("utf-8")
    if len(b) <= n:
        return text
    return b[:n].decode("utf-8", "ignore")


def run_now(run_dir, lines, numbered, live, ended):
    """`now`: the live stage, else the last handoff's blocked point while no
    stage result has followed it; None for an ended or reclaimed run and for
    neither."""
    if run_dir is None:
        return None
    if live:
        name = live[0]
        attempt = None
        f = os.path.join(run_dir, name + ".attempt")
        if os.path.isfile(f):
            attempt = _strip_blanks(read_text(f) or "") or None
        return {"stage": name, "kind": stage_kind(run_dir, lines, name), "attempt": attempt, "blocked": None}
    if ended:
        return None
    last_handoff = None
    for no, ln in numbered:
        if ln.startswith("- `handoff`"):
            last_handoff = ln
        elif ln.startswith("- `stage-result`"):
            last_handoff = None
    if last_handoff is None:
        return None
    point = split_fields(last_handoff).get("막힌 지점")
    if not point:
        return None
    return {"stage": None, "kind": None, "attempt": None, "blocked": point.split("\n", 1)[0]}


_RESULT_PREFIX = (("종료 조건 성립", "종료 조건 성립"), ("경계 ", "경계"), ("무효화", "무효화"),
                  ("질의 잔여 ", "질의 잔여"), ("P0 잔존", "P0 잔존"))


def run_result(run_dir, state):
    """`result` of an ended run, from the first line of `done`."""
    if state != "종단":
        return None
    if run_dir is None:
        return {"class": "미상", "label": None, "line": None}
    text = read_text(os.path.join(run_dir, "done"))
    if text is None:
        return {"class": "파생 종단", "label": None, "line": None}
    line = text.split("\n", 1)[0]
    head, _sp, rest = line.partition(" ")
    if not _ISO.fullmatch(head):
        rest = line
    out = {"class": "미상", "label": None, "line": line}
    if rest.startswith("종단 — "):
        body = rest[len("종단 — "):]
        for prefix, cls in _RESULT_PREFIX:
            if body.startswith(prefix):
                out["class"] = cls
                if cls == "경계":
                    out["label"] = "경계 " + body[len(prefix):].split(" ", 1)[0]
                break
    return out


def is_experiment(base):
    """Whether a run's base sits under `<state home>/cc-cmds/`."""
    if not base:
        return False
    b = os.path.realpath(base.rstrip("/") or "/")
    home = os.path.realpath(state_home().rstrip("/") or "/")
    return b.startswith(home.rstrip("/") + "/cc-cmds/")


def today_share(points, midnight):
    """The last cumulative cost less the last one observed before midnight."""
    if not points:
        return 0.0
    before = 0.0
    for t, cum in points:
        if t is not None and t < midnight:
            before = cum
    return points[-1][1] - before


def waiting_stamp(run_dir):
    try:
        names = sorted(n for n in os.listdir(run_dir) if n.endswith(".waiting") and not n.startswith("."))
    except OSError:
        return ()
    out = []
    for n in names:
        try:
            out.append((n, os.stat(os.path.join(run_dir, n)).st_mtime_ns))
        except OSError:
            pass
    return tuple(out)


class Model:
    """Every run under the run root and every reclaimed ledger beside them."""

    def __init__(self, root=None, stall=STALL_S, abandon=ABANDON_S, window=WINDOW_S):
        self.root = root or run_root()
        self.stall = stall
        self.abandon = abandon
        self.window = window
        self.sources = {}
        self.shells = []
        self.manifests = {}
        self.dur_cache = {}

    # -- discovery ---------------------------------------------------------

    def discover(self):
        try:
            names = sorted(os.listdir(self.root))
        except OSError:
            names = []
        seen = set()
        shells = []
        ledgers = set()
        for name in names:
            rd = os.path.join(self.root, name)
            if not os.path.isdir(rd):
                continue
            lp_file = os.path.join(rd, "ledger-path")
            if not os.path.isfile(lp_file):
                shells.append(name)
                continue
            lp = cmd_subst(lp_file).strip()
            seen.add(name)
            src = self.sources.get(name)
            if src is None or src.ledger_path != lp or src.run_dir != rd:
                src = RunSource(name, rd, lp)
                self.sources[name] = src
            if lp:
                ledgers.add(os.path.realpath(lp))
        bases = set()
        for src in list(self.sources.values()):
            if src.run_dir and src.id in seen and src.base and os.path.exists(os.path.join(src.base, ".git")):
                bases.add(src.base)
        for base in sorted(bases):
            pdir = os.path.join(base, "docs", "pipeline-run")
            try:
                files = sorted(os.listdir(pdir))
            except OSError:
                continue
            for fn in files:
                stem = fn[:-3] if fn.endswith(".md") else None
                if stem is None or "." in stem:
                    continue
                if os.path.isdir(os.path.join(self.root, stem)):
                    continue
                path = os.path.join(pdir, fn)
                if os.path.realpath(path) in ledgers:
                    continue
                key = "reclaimed:" + path
                src = self.sources.get(key)
                if src is None:
                    if not is_ledger_file(path):
                        continue
                    src = RunSource(stem, None, path)
                    self.sources[key] = src
                seen.add(key)
        for key in list(self.sources):
            if key not in seen:
                del self.sources[key]
        self.shells = shells

    def find(self, run_id):
        src = self.sources.get(run_id)
        if src is not None:
            return src
        for key, s in self.sources.items():
            if s.run_dir is None and s.id == run_id:
                return s
        return None

    def manifest(self, src):
        if not src.base:
            return None
        path = os.path.join(src.base, "docs", "pipeline-run", src.id + ".plan.md")
        try:
            st = os.stat(path)
        except OSError:
            return None
        key = (st.st_ino, st.st_size, st.st_mtime_ns)
        hit = self.manifests.get(path)
        if hit and hit[0] == key:
            return hit[1]
        m = parse_manifest(path)
        self.manifests[path] = (key, m)
        return m

    # -- per-run evaluation ------------------------------------------------

    def _growth(self, src):
        if src.run_dir is None:
            return src.ledger.mtime if src.ledger and not src.ledger.missing else None
        v, present = heartbeat_growth(src.run_dir)
        if v is not None:
            src.hb_value = v
        elif present and src.hb_value is not None:
            # A heartbeat is rewritten with `>`, so a reader can catch it empty.
            # An empty read keeps the previous value rather than falling back.
            v = src.hb_value
        if v is not None:
            return v
        if src.ledger and not src.ledger.missing:
            return src.ledger.mtime
        return None

    def evaluate(self, src, procs, now):
        if src.ledger:
            src.ledger.refresh()
        key = stamp_key(src)
        if src.frozen is not None and src.frozen_key == key:
            out = dict(src.frozen)
            self._band(out, now)
            return out
        lines = src.ledger.lines() if src.ledger else []
        live = live_stages(src.run_dir, procs) if src.run_dir else []
        growth = self._growth(src)
        if src.run_dir is None:
            state = run_state_reclaimed(lines, growth, now, self.stall, self.abandon)
        else:
            state = run_state(src.run_dir, lines, src.ledger_path, procs, self.stall, self.abandon,
                              now=now, growth=growth, live=live)
            # The shell answers a `done` run before it reads any growth clock,
            # so the done-tail's 정산중 is not the age ladder's and stays.
            if (growth is None and state not in ("도는중", "종단", "승인대기")
                    and not os.path.isfile(os.path.join(src.run_dir, "done"))):
                state = "버려짐"
        seg_state = {}
        for ln in src.ledger.series("segment") if src.ledger else []:
            f = split_fields(ln)
            sid = f.get("id")
            if sid:
                seg_state[sid] = f.get("상태", "")
        seg = {"total": len(seg_state), "merged": 0, "done": 0, "park": 0, "open": 0}
        for st in seg_state.values():
            if st == "머지됨":
                seg["merged"] += 1
            elif st == "완료":
                seg["done"] += 1
            elif st == "park":
                seg["park"] += 1
            else:
                seg["open"] += 1
        cost = None
        points = []
        for ln in src.ledger.series("cost") if src.ledger else []:
            f = split_fields(ln)
            try:
                cost = float(f.get("누적 usd"))
            except (TypeError, ValueError):
                continue
            points.append((iso_epoch(f.get("관측 시각")), cost))
        src.cost_points = points
        manifest = self.manifest(src)
        watch_age = None
        if src.run_dir:
            hbm = mtime_s(os.path.join(src.run_dir, "watch.heartbeat"))
            if hbm is not None:
                watch_age = max(0, now - hbm)
        if src.run_dir is None:
            ended = None
            for ln in src.ledger.series("cost") if src.ledger else []:
                t = iso_epoch(split_fields(ln).get("관측 시각"))
                if t is not None:
                    ended = t
            if ended is None and src.ledger:
                ended = src.ledger.mtime
        elif state == "종단":
            ended = mtime_s(os.path.join(src.run_dir, "done"))
            if ended is None and src.ledger:
                ended = src.ledger.mtime
        else:
            ended = src.ledger.mtime if src.ledger and not src.ledger.missing else None
        notes = []
        if src.run_dir is None:
            notes.append("런 디렉터리 회수됨")
        if src.ledger is None or src.ledger.missing:
            notes.append("원장 없음")
        if manifest is None:
            notes.append("매니페스트 없음")
        out = {
            "id": src.id,
            "base": src.base,
            "slug": (manifest or {}).get("anchor"),
            "state": state,
            "grade": run_grade(state),
            "goal": (manifest or {}).get("goal"),
            "last_growth": growth,
            "cost_usd": cost,
            "seg": seg,
            "live_stages": live,
            "watch_age_s": watch_age,
            "run_dir": src.run_dir,
            "ended_at": ended,
            "notes": notes,
        }
        led = src.ledger
        numbered = led.numbered() if led else []
        halts = unanswered_halt_records(src.run_dir, numbered) if src.run_dir else []
        waiters = (waiting_fresh(src.run_dir, lines, src.ledger_path, procs, now=now)
                   if src.run_dir else [])
        out["waiting"] = waiting_items(open_approval_rows(lines), halts, waiters)
        out["now"] = run_now(src.run_dir, lines, numbered, live, state == "종단")
        out["result"] = run_result(src.run_dir, state)
        out["prs"] = run_prs(led.series("segment") if led else [], manifest)
        started = None
        for ln in led.series("run") if led else []:
            started = iso_epoch(split_fields(ln).get("시작"))
            break
        if started is None and led:
            started = led.first_time
        out["started_at"] = started
        dl = (manifest or {}).get("deadline")
        dl_epoch = iso_epoch(dl)
        out["deadline"] = dl_epoch if dl_epoch is not None else dl
        out["experiment"] = is_experiment(src.base)
        if state == "종단":
            src.frozen = dict(out)
            src.frozen_key = key
        else:
            src.frozen = None
            src.frozen_key = None
        self._band(out, now)
        return out

    def _band(self, out, now):
        state = out["state"]
        notes = [n for n in out["notes"] if n != "승인대기(오래됨)"]
        if out["run_dir"] is None:
            band = "older"
        elif state in ("도는중", "진행중", "정산중", "정지경고"):
            band = "live"
        elif state == "승인대기":
            g = out.get("last_growth")
            if g is not None and now - g < self.window:
                band = "live"
            else:
                band = "older"
                notes.append("승인대기(오래됨)")
        else:
            e = out.get("ended_at")
            band = "recent" if e is not None and now - e < self.window else "older"
        out["band"] = band
        out["notes"] = notes
        asking = any(w["kind"] in ("승인", "중단 기록") for w in out["waiting"])
        if state != "종단" and out["run_dir"] is not None and asking:
            attention = "need"
        elif state == "종단":
            attention = "ended"
        elif state == "버려짐":
            attention = "dead"
        else:
            attention = "watch"
        out["attention"] = attention
        out["hidden"] = attention == "dead"
        s = out["started_at"]
        if s is None:
            out["elapsed_s"] = None
        elif state == "종단":
            out["elapsed_s"] = out["ended_at"] - s if out["ended_at"] is not None else None
        else:
            out["elapsed_s"] = now - s
        dl = out["deadline"]
        out["deadline_left_s"] = dl - now if isinstance(dl, int) else None
        e = out["ended_at"]
        out["ended_day"] = day_key(e, display_tz()[0]) if e is not None else None

    # -- the list ----------------------------------------------------------

    def runs(self, days="3", base=None, dead=False, now=None, exp=False):
        """The list. The base filter comes first, so a run outside the chosen
        base is in no hidden count; then the two hiding reasons, each run
        counted once (an experiment first); then the period, which a `need`
        run does not get. `bases` is gathered after experiment hiding alone."""
        if now is None:
            now = int(time.time())
        self.discover()
        procs = ProcTable()
        span = None if days == "all" else int(days) * 86400
        off, label = display_tz()
        midnight = day_start(now, off)
        rows = []
        hidden = len(self.shells)
        hidden_exp = 0
        bases = set()
        period_usd = today_usd = 0.0
        by_base = {}
        for key in sorted(self.sources):
            src = self.sources[key]
            r = self.evaluate(src, procs, now)
            if exp or not r["experiment"]:
                if r["base"]:
                    bases.add(r["base"])
            if base and r["base"] != base:
                continue
            if r["experiment"] and not exp:
                hidden_exp += 1
                continue
            if r["hidden"] and not dead:
                hidden += 1
                continue
            if r["attention"] != "need" and r["band"] != "live" and span is not None:
                t = r["ended_at"] if r["ended_at"] is not None else r["last_growth"]
                if t is None or now - t > span:
                    continue
            r["waiting"] = [dict(w, text=clip_bytes(w["text"])) for w in r["waiting"]]
            rows.append(r)
            k = r["base"] or "-"
            by_base[k] = by_base.get(k, 0.0) + (r["cost_usd"] or 0.0)
            period_usd += r["cost_usd"] or 0.0
            today_usd += today_share(src.cost_points, midnight)
        if dead:
            for name in self.shells:
                rows.append({
                    "id": name, "base": None, "slug": None, "state": "버려짐", "grade": 6,
                    "band": "older", "goal": None, "last_growth": None, "cost_usd": None,
                    "seg": {"total": 0, "merged": 0, "done": 0, "park": 0, "open": 0},
                    "live_stages": [], "watch_age_s": None,
                    "run_dir": os.path.join(self.root, name), "ended_at": None,
                    "notes": ["ledger-path 없음"], "hidden": True,
                    "attention": "dead", "waiting": [], "now": None, "result": None, "prs": [],
                    "experiment": False, "started_at": None, "elapsed_s": None, "deadline": None,
                    "deadline_left_s": None, "ended_day": None,
                })
                by_base["-"] = by_base.get("-", 0.0)
        rows.sort(key=lambda r: (0 if r["band"] == "live" else 1,
                                 r["grade"] if r["band"] == "live" else 0,
                                 -(r["ended_at"] or r["last_growth"] or 0)))
        return {"generated_at": now, "runs": rows, "hidden": hidden, "bases": sorted(bases),
                "hidden_experiment": hidden_exp,
                "totals": {"period_usd": period_usd, "today_usd": today_usd, "by_base": by_base},
                "today": day_key(now, off), "tz_label": label, "tz_offset_s": off}

    def live_count(self, now=None):
        """The idle check's census: live as the top band defines it.

        A directory whose `done` is settled reads 종단 and is skipped; one whose
        `done` is not settled yet is the done-tail's 정산중 and is evaluated
        whatever its growth clock says. Otherwise only directories whose growth
        clock is inside the window are evaluated, since nothing outside that set
        can be in the top band.
        """
        if now is None:
            now = int(time.time())
        self.discover()
        procs = None
        n = 0
        for src in self.sources.values():
            if src.run_dir is None:
                continue
            done = os.path.isfile(os.path.join(src.run_dir, "done"))
            if done:
                if procs is None:
                    procs = ProcTable()
                if run_end_settled(src.run_dir, procs):
                    continue
            if src.ledger:
                src.ledger.refresh()
            g = self._growth(src)
            if not done and (g is None or now - g >= self.window):
                continue
            if procs is None:
                procs = ProcTable()
            r = self.evaluate(src, procs, now)
            if r["band"] == "live":
                n += 1
        return n

    # -- the detail --------------------------------------------------------

    def detail(self, run_id, now=None):
        if now is None:
            now = int(time.time())
        self.discover()
        src = self.find(run_id)
        if src is None:
            return None
        procs = ProcTable()
        summary = self.evaluate(src, procs, now)
        manifest = self.manifest(src)
        led = src.ledger
        lines = led.lines() if led else []

        clauses = []
        latest = {}
        for ln in led.series("종료 절") if led else []:
            f = split_fields(ln)
            if f.get("id"):
                latest[f["id"]] = f.get("상태", "")
        for c in (manifest or {}).get("clauses", []):
            clauses.append({"id": c["id"], "text": c["text"], "state": latest.get(c["id"]) or "미판정"})

        segments = []
        index = {}
        for ln in led.series("segment") if led else []:
            f = split_fields(ln)
            sid = f.get("id")
            if not sid:
                continue
            if sid not in index:
                index[sid] = {"id": sid, "state": "", "history": [], "deps": [], "branch": None, "cycles": []}
                segments.append(index[sid])
            s = index[sid]
            s["state"] = f.get("상태", "")
            s["history"].append(f.get("상태", ""))
            dep = f.get("선행")
            if dep is not None:
                s["deps"] = [d for d in re.split(r"[,\s]+", dep) if d and d not in ("없음", "-")]
            if f.get("브랜치"):
                s["branch"] = f["브랜치"]
        for ln in led.series("cycle") if led else []:
            f = split_fields(ln)
            sid = f.get("세그먼트")
            if not sid:
                continue
            if sid not in index:
                index[sid] = {"id": sid, "state": "", "history": [], "deps": [], "branch": None, "cycles": []}
                segments.append(index[sid])
            index[sid]["cycles"].append({
                "cycle": f.get("사이클"), "p0": _int(f.get("P0")), "p1": _int(f.get("P1")),
                "mode": f.get("모드"),
            })

        timeline = self._timeline(src)
        shifts = []
        for ln in led.series("교대 기동") if led else []:
            f = split_fields(ln)
            shifts.append({"ordinal": f.get("서수"), "reason": f.get("사유"), "at": iso_epoch(f.get("기록 시각"))})

        run_start = None
        for ln in led.series("run") if led else []:
            run_start = iso_epoch(split_fields(ln).get("시작"))
            break
        if run_start is None and led:
            run_start = led.first_time

        ceiling = ceiling_usd((manifest or {}).get("ceiling"))
        cost = {
            "usd": summary["cost_usd"],
            "ceiling": ceiling,
            "ratio": (summary["cost_usd"] / ceiling) if (ceiling and summary["cost_usd"] is not None) else None,
            "unknown": sum(1 for t in timeline if t["usd"] is None),
            "external_end": sum(1 for t in timeline if t["class"] == "외부 종료"),
        }
        hb = {"watch_age_s": summary["watch_age_s"], "last_growth": summary["last_growth"],
              "feed_age_s": None, "live_stages": summary["live_stages"]}
        done_text = None
        if src.run_dir:
            fm = mtime_s(os.path.join(src.run_dir, "feed.heartbeat"))
            if fm is not None:
                hb["feed_age_s"] = max(0, now - fm)
            t = read_text(os.path.join(src.run_dir, "done"))
            if t is not None:
                done_text = t.strip()
        attempts = run_attempts(led, timeline)
        steps, owner = run_steps((manifest or {}).get("steps") or [], attempts, segments,
                                 summary["live_stages"], src.run_dir)
        cost.update(cost_split(summary["cost_usd"], attempts, owner))
        mpath = os.path.join(src.base, "docs", "pipeline-run", src.id + ".plan.md") if src.base else None
        run_fields = split_fields(led.series("run")[0]) if led and led.series("run") else {}
        reviews = run_reviews(led.series("cycle") if led else [])
        return {
            "summary": summary,
            "steps": steps,
            "waiting": summary["waiting"],
            "judgments": run_judgments(led),
            "reviews": reviews,
            "links": {
                "prs": summary["prs"],
                "branches": [{"seg": s["id"], "branch": s["branch"]} for s in segments if s["branch"]],
                "design_doc": run_fields.get("설계 문서"),
                "report": run_fields.get("보고서"),
                "review_reports": [{"seg": r["seg"], "cycle": c["사이클"], "path": c["리포트 경로"]}
                                   for r in reviews for c in r["cycles"] if c["리포트 경로"]],
                "ledger": src.ledger_path,
                "manifest": mpath if mpath and os.path.isfile(mpath) else None,
            },
            "result": summary["result"],
            "tz_offset_s": display_tz()[0],
            "manifest": None if manifest is None else {
                "steps": manifest["steps"], "goal": manifest["goal"],
                "deadline": manifest["deadline"], "ceiling": manifest["ceiling"],
            },
            "clauses": clauses,
            "derived": {
                "nonterminal_segments": nonterminal_segments(lines),
                "open_approvals": open_approvals(lines),
                "unresolved_blocks": len(unresolved_blocked(lines)),
            },
            "segments": segments,
            "timeline": [{k: v for k, v in t.items() if k != "_line"} for t in timeline],
            "shifts": shifts,
            "run_start": run_start,
            "cost": cost,
            "heartbeat": hb,
            "done_text": done_text,
            "has_sup": bool(src.run_dir) and self._has_sup(src.run_dir),
        }

    def _has_sup(self, run_dir):
        try:
            return any(n.endswith(".sup.log") for n in os.listdir(os.path.join(run_dir, "log")))
        except OSError:
            return False

    def _duration(self, path):
        try:
            st = os.stat(path)
        except OSError:
            return None
        key = (st.st_ino, st.st_size, st.st_mtime_ns)
        hit = self.dur_cache.get(path)
        if hit and hit[0] == key:
            return hit[1]
        v = result_duration_ms(path)
        self.dur_cache[path] = (key, v)
        return v

    def _timeline(self, src):
        led = src.ledger
        if not led:
            return []
        logd = os.path.join(src.run_dir, "log") if src.run_dir else None
        has_sup = bool(logd) and self._has_sup(src.run_dir)
        out = []
        pending = None
        prev_cum = None
        for (series, ln), no in zip(led.rows, led.linenos):
            if series == "stage-result":
                f = split_fields(ln)
                pending = {
                    # The ledger line of the row that opened the attempt, which
                    # the step and cost views key on; never in the response.
                    "_line": no,
                    "stage": f.get("스테이지") or f.get("세그먼트"),
                    "attempt": f.get("실행 버전"),
                    "kind": f.get("종류"),
                    "class": f.get("종단 부류"),
                    "rc": _int(f.get("종료 코드")),
                    "shift": f.get("교대"),
                    "start": None, "start_src": "없음",
                    "end": None, "end_src": "없음",
                    "duration_s": None,
                    "usd": None,
                    "reattach": None,
                }
                out.append(pending)
            elif series == "cost":
                f = split_fields(ln)
                try:
                    cum = float(f.get("누적 usd"))
                except (TypeError, ValueError):
                    cum = None
                if pending is not None:
                    if cum is not None:
                        pending["usd"] = cum - (prev_cum or 0.0)
                    t = iso_epoch(f.get("관측 시각"))
                    if t is not None:
                        pending["end"], pending["end_src"] = t, "cost"
                    pending = None
                if cum is not None:
                    prev_cum = cum
        for t in out:
            if not logd or not t["stage"]:
                continue
            stem = os.path.join(logd, "%s#%s" % (t["stage"], t["attempt"]))
            sup = read_sup(stem + ".sup.log") if has_sup else None
            if sup:
                if sup["start"] is not None:
                    t["start"], t["start_src"] = sup["start"], "sup"
                if sup["end"] is not None:
                    t["end"], t["end_src"] = sup["end"], "sup"
                t["reattach"] = sup["reattach"]
            if t["start"] is None:
                try:
                    st = os.stat(stem + ".err")
                    if st.st_size == 0:
                        t["start"], t["start_src"] = int(st.st_mtime // 1), "err"
                except OSError:
                    pass
            if t["start"] is None and t["end"] is not None:
                d = self._duration(stem + ".json")
                if d is not None:
                    t["start"], t["start_src"] = int(t["end"] - d / 1000.0), "duration"
            if t["start"] is not None and t["end"] is not None:
                t["duration_s"] = max(0, t["end"] - t["start"])
            elif t["end"] is None or t["start"] is None:
                d = self._duration(stem + ".json")
                if d is not None and t["start"] is None and t["end"] is None:
                    t["duration_s"] = int(d / 1000.0)
                    t["start_src"] = "duration"
        return out


def run_state_reclaimed(lines, growth, now, stall=STALL_S, abandon=ABANDON_S):
    """A reclaimed run's state: `cc_run_state` with no run directory.

    With no directory there is no pid, heartbeat or `done` to read, so no stage
    is live, `done` is absent and the growth clock is the ledger's mtime; the
    same rules run, in the same order, on what is left.
    """
    blocked_n = len(unresolved_blocked(lines))
    pend = open_approvals(lines)
    nonterm = len(nonterminal_segments(lines))
    if blocked_n == 0 and pend == 0 and nonterm == 0 and segment_count(lines) >= 1:
        return "종단"
    if pend > 0:
        return "승인대기"
    if growth is None:
        return "버려짐"
    idle = max(0, now - growth)
    if idle >= abandon:
        return "버려짐"
    if idle >= stall:
        return "정지경고"
    return "진행중"


# ---------------------------------------------------------------------------
# The detail's step, judgment and review views
# ---------------------------------------------------------------------------

# The gate's `gate_run_scope_skill_of`, read backwards: plan skill → row kind.
_SKILL_KIND = {"design": "design", "design-audit": "audit", "split": "split",
               "visual": "visual", "visual-publish": "visual-publish"}
# The driver's names for a run-scope kind, as `gate_run_scope_rows` reads them.
_DRIVER_NAME = {"audit": "S2", "split": "S2split", "visual": "S2V", "visual-publish": "S2P"}
# The driver's `stage_kind_of` for a segment stage that wrote no `종류`.
_DRIVER_KIND = {"S4": "implement", "S5": "review", "S5R": "review", "S5F": "lead-fix"}
# The plan skill of the step a segment attempt of that kind belongs to.
_SEG_STEP_SKILL = {"implement": "implement", "review": "review", "lead-fix": "review"}
_STATUS_ORDER = ("도는 중", "실패", "대기", "park", "끝남")


def run_attempts(led, timeline):
    """One record per `stage-result` row, keyed to its timeline entry by line."""
    by_line = {t["_line"]: t for t in timeline}
    out = []
    for no, ln in led.numbered("stage-result") if led else []:
        kinds = _field_whole_values(ln, "종류")
        segs = _field_whole_values(ln, "세그먼트")
        stages = _field_whole_values(ln, "스테이지")
        kind = kinds[-1] if kinds and kinds[-1] else None
        stage = stages[0] if stages else None
        out.append({
            "line": no, "segs": segs, "stage": stage, "kind": kind, "has_kind": bool(kinds),
            "seg_kind": kind or _DRIVER_KIND.get(stage or ""),
            "class": split_fields(ln).get("종단 부류"), "item": by_line.get(no),
        })
    return out


def _status_of(tries):
    if not tries:
        return "대기"
    cls = tries[-1]["class"]
    if cls == "정상 완료":
        return "끝남"
    if cls == "의도된 park":
        return "park"
    if cls == "한도 종료":
        return "대기"
    return "실패"


def _span(tries):
    items = [a["item"] for a in tries if a["item"]]
    starts = [t["start"] for t in items if t["start"] is not None]
    ends = [t["end"] for t in items if t["end"] is not None]
    usds = [t["usd"] for t in items if t["usd"] is not None]
    return (min(starts) if starts else None, max(ends) if ends else None,
            sum(usds) if usds else None)


def _run_scope_tries(step_id, kind, attempts):
    """The step's attempts the way the gate finds them, its own `종류=reconverge`
    rows beside them in ledger order."""
    scoped = [a for a in attempts if "-" in a["segs"]]
    own = [a for a in scoped if a["stage"] == step_id and a["kind"] == kind] if kind else []
    if not own and kind in _DRIVER_NAME:
        name = _DRIVER_NAME[kind]
        own = [a for a in scoped if a["stage"] == name
               and (a["kind"] == kind or (kind == "audit" and not a["has_kind"]))]
    if kind is None:
        own = [a for a in scoped if a["stage"] == step_id and a["kind"] != "reconverge"]
    again = [a for a in scoped if a["stage"] == step_id and a["kind"] == "reconverge"]
    return sorted(own + again, key=lambda a: a["line"])


def run_steps(plan_steps, attempts, segments, live, run_dir):
    """`steps` in plan order, and the step id each attempt line is counted under."""
    owner = {}
    skills = [s["skill"] for s in plan_steps]
    out = []
    for step in plan_steps:
        sid, skill = step["id"], step["skill"]
        children = []
        if skill in ("implement", "review"):
            unique = skills.count(skill) == 1
            tries = []
            for seg in segments:
                mine = [a for a in attempts if seg["id"] in a["segs"]]
                attached = [a for a in mine if unique and _SEG_STEP_SKILL.get(a["seg_kind"]) == skill]
                if seg["state"] == "머지됨":
                    st = "끝남"
                elif seg["state"] == "park":
                    st = "park"
                elif seg["id"] in live and unique and _SEG_STEP_SKILL.get(
                        _live_kind(run_dir, seg["id"], mine)) == skill:
                    st = "도는 중"
                else:
                    st = _status_of(attached)
                children.append({"id": seg["id"], "status": st, "attempts": len(attached)})
                tries.extend(attached)
            tries.sort(key=lambda a: a["line"])
            status = next((s for s in _STATUS_ORDER if any(c["status"] == s for c in children)), "대기")
            kind = tries[-1]["seg_kind"] if tries else None
        else:
            kind = _SKILL_KIND.get(skill)
            tries = _run_scope_tries(sid, kind, attempts)
            names = {sid, _DRIVER_NAME.get(kind or "")}
            status = "도는 중" if any(n in names for n in live) else _status_of(tries)
            kind = tries[-1]["kind"] if tries else None
        for a in tries:
            owner.setdefault(a["line"], sid)
        started, ended, usd = _span(tries)
        out.append({"id": sid, "skill": skill, "kind": kind, "status": status, "attempts": len(tries),
                    "end_class": tries[-1]["class"] if tries else None,
                    "started": started, "ended": ended, "usd": usd, "segments": children})
    return out, owner


def _live_kind(run_dir, seg, mine):
    """A live segment stage's kind: its `.kind`, else its last attempt's kind."""
    f = os.path.join(run_dir, seg + ".kind") if run_dir else ""
    if f and os.path.isfile(f):
        k = _strip_blanks(read_text(f) or "")
        if k:
            return k
    return mine[-1]["seg_kind"] if mine else None


def cost_split(total, attempts, owner):
    """`by_step`·`by_kind`·`by_segment`, each summing to `total`; whatever no
    attempt carries goes to `기타`."""
    out = {"by_step": {}, "by_kind": {}, "by_segment": {}}
    if total is None:
        return out
    for a in attempts:
        usd = a["item"]["usd"] if a["item"] else None
        if usd is None:
            continue
        segs = [s for s in a["segs"] if s and s != "-"]
        for name, key in (("by_step", owner.get(a["line"])), ("by_kind", a["seg_kind"]),
                          ("by_segment", segs[0] if segs else None)):
            k = key or "기타"
            out[name][k] = out[name].get(k, 0.0) + usd
    for name in out:
        rest = total - sum(out[name].values())
        if abs(rest) > 1e-9:
            out[name]["기타"] = out[name].get("기타", 0.0) + rest
    return out


def run_reviews(cycle_rows):
    """Per segment, its `cycle` rows; a field an older gate did not write is null."""
    out = []
    index = {}
    for ln in cycle_rows:
        f = split_fields(ln)
        sid = f.get("세그먼트")
        if not sid:
            continue
        if sid not in index:
            index[sid] = {"seg": sid, "cycles": []}
            out.append(index[sid])
        index[sid]["cycles"].append({
            "사이클": f.get("사이클"), "P0": _int(f.get("P0")), "P1": _int(f.get("P1")),
            "모드": f.get("모드"), "리뷰 종결": f.get("리뷰 종결"), "리포트 경로": f.get("리포트 경로"),
        })
    return out


_AUTO_ANSWER = "자동 채택(구속-이탈) — "
_JUDGMENT_KEYS = ("결정", "세그먼트", "판단 부류", "등급", "기준", "되돌리는 법", "근거", "해소 승인")


def _answered_by(f):
    """gate_halt_answered_by — a row without `답한 주체` is the shift's when its
    reason carries the shift's prefix, and a person's otherwise."""
    by = f.get("답한 주체")
    if by:
        return by
    return "교대" if (f.get("근거") or "").startswith(_AUTO_ANSWER) else "사람"


def _judgment(at, source, values):
    item = {"at": at, "source": source}
    for k in _JUDGMENT_KEYS:
        item[k] = values.get(k)
    return item


def run_judgments(led):
    """The run's autonomous decisions in ledger order, and their count per class.

    A judgment closed by an automatic resolution is two rows, the judgment
    naming the approval and the approval row closing it; the pair is one item.
    """
    if not led:
        return {"items": [], "by_class": {}}
    approvals = [(no, split_fields(ln)) for no, ln in led.numbered("승인")]
    items = []
    paired = set()
    for no, ln in led.judged:
        f = split_fields(ln)
        aid = f.get("해소 승인")
        at = None
        if aid and aid != "-":
            paired.add(aid)
            for _n, a in approvals:
                if a.get("승인 id") == aid and a.get("해소 시각") not in (None, "", "-"):
                    at = iso_epoch(a["해소 시각"])
        items.append((no, _judgment(at, "판단", f)))
    for no, ln in led.numbered("중단 답"):
        f = split_fields(ln)
        if _answered_by(f) not in ("좌석", "교대"):
            continue
        items.append((no, _judgment(iso_epoch(f.get("기록 시각")), "자동 답",
                                    {"결정": f.get("선택지"), "세그먼트": f.get("세그먼트"),
                                     "근거": f.get("근거")})))
    seen = set()
    for no, a in approvals:
        aid = a.get("승인 id")
        if a.get("처분 사유") != "자동 해소" or not aid or aid in paired or aid in seen:
            continue
        seen.add(aid)
        items.append((no, _judgment(iso_epoch(a.get("해소 시각")), "자동 해소",
                                    {"결정": a.get("답변 문면"), "해소 승인": aid})))
    items.sort(key=lambda p: p[0])
    by_class = {}
    for _no, it in items:
        c = it["판단 부류"]
        if c:
            by_class[c] = by_class.get(c, 0) + 1
    return {"items": [it for _no, it in items], "by_class": by_class}


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# A command line, for the agreement suite
# ---------------------------------------------------------------------------

def _main(argv):
    if len(argv) >= 2 and argv[0] == "live-stages":
        print(len(live_stages(argv[1], ProcTable())))
        return 0
    if len(argv) >= 2 and argv[0] == "live-names":
        print(",".join(live_stages(argv[1], ProcTable())))
        return 0
    if len(argv) >= 3 and argv[0] == "state":
        stall = int(argv[3]) if len(argv) > 3 else STALL_S
        abandon = int(argv[4]) if len(argv) > 4 else ABANDON_S
        print(run_state(argv[1], read_ledger_lines(argv[2]), argv[2], ProcTable(), stall, abandon))
        return 0
    if len(argv) >= 2 and argv[0] == "model-state":
        # The server's path — discovery, `Ledger` and `Model.evaluate` — over
        # one run directory, so the agreement suite reaches it as well.
        rd = os.path.abspath(argv[1])
        stall = int(argv[2]) if len(argv) > 2 else STALL_S
        abandon = int(argv[3]) if len(argv) > 3 else ABANDON_S
        m = Model(root=os.path.dirname(rd), stall=stall, abandon=abandon)
        m.discover()
        src = m.find(os.path.basename(rd))
        if src is None:
            print("없음")
            return 1
        print(m.evaluate(src, ProcTable(), int(time.time()))["state"])
        return 0
    if len(argv) >= 2 and argv[0] == "grade":
        print(run_grade(argv[1]))
        return 0
    if len(argv) >= 2 and argv[0] == "unanswered-halts":
        # The ledger goes through `Ledger`, so the line numbers the dashboard
        # keys a returned answer on are the ones the agreement suite compares.
        lp = argv[2] if len(argv) > 2 else ""
        numbered = None
        if lp:
            led = Ledger(lp)
            led.refresh()
            numbered = led.numbered()
        print(len(unanswered_halt_records(argv[1], numbered)))
        return 0
    if len(argv) >= 1 and argv[0] == "display-tz":
        off, label = display_tz(argv[1] if len(argv) > 1 else None)
        print("%d %s" % (off, label))
        return 0
    print("usage: dashboard_read.py live-stages|live-names <run-dir> | state <run-dir> <ledger> [stall abandon]"
          " | model-state <run-dir> [stall abandon] | grade <token> | unanswered-halts <run-dir> <ledger>"
          " | display-tz [value]")
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv[1:]))
