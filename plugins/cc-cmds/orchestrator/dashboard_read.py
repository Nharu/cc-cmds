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
`cc_ledger_growth_at` and `cc_mtime` each have a function below that reads the
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
    ["segment", "승인", "blocked", "cycle", "stage-result", "cost", "교대 기동", "run", "종료 절"]
)

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


def open_approvals(lines):
    """cc_open_approvals."""
    rows = _rows(lines, "승인")
    values = set()
    for ln in rows:
        values.update(_field_values(ln, "승인 id"))
    n = 0
    for aid in _loop_words(values):
        last = None
        needle = "| 승인 id=%s |" % aid
        for ln in rows:
            if needle in ln:
                last = ln
        if last is not None and _field_last(last, "상태") == "대기":
            n += 1
    return n


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
        elif scope == "cone" and anchor != "" and anchor not in seg:
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
    if not run_dir:
        return 0
    try:
        names = sorted(os.listdir(run_dir))
    except OSError:
        return 0
    n = 0
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
            n += 1
    return n


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
            self._ingest(raw.decode("utf-8", "replace"))

    def _ingest(self, line):
        if self.first_line is None:
            self.first_line = line
        m = _ROW_HEAD.match(line)
        if m and self.first_time is None:
            t = iso_epoch(line)
            if t is not None:
                self.first_time = t
        if m and m.group(1) in KEEP_SERIES:
            self.rows.append((m.group(1), line))
        elif "계보=B:" in line:
            # The blocked fold releases a step cone on a later attempt's lineage,
            # which any line may carry, so those lines are kept in file order.
            self.rows.append((m.group(1) if m else None, line))

    def lines(self):
        return [ln for _s, ln in self.rows]

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
    out = {"steps": [], "goal": None, "deadline": None, "ceiling": None, "clauses": [], "anchor": None}
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
    return out


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
    )


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
        for ln in src.ledger.series("cost") if src.ledger else []:
            v = split_fields(ln).get("누적 usd")
            try:
                cost = float(v)
            except (TypeError, ValueError):
                pass
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
        out["hidden"] = state == "버려짐"
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

    # -- the list ----------------------------------------------------------

    def runs(self, days="3", base=None, dead=False, now=None):
        if now is None:
            now = int(time.time())
        self.discover()
        procs = ProcTable()
        span = None if days == "all" else int(days) * 86400
        rows = []
        hidden = len(self.shells)
        for key in sorted(self.sources):
            src = self.sources[key]
            r = self.evaluate(src, procs, now)
            if base and r["base"] != base:
                continue
            if r["hidden"] and not dead:
                hidden += 1
                continue
            if r["band"] != "live" and span is not None:
                t = r["ended_at"] if r["ended_at"] is not None else r["last_growth"]
                if t is None or now - t > span:
                    continue
            rows.append(r)
        if dead:
            for name in self.shells:
                rows.append({
                    "id": name, "base": None, "slug": None, "state": "버려짐", "grade": 6,
                    "band": "older", "goal": None, "last_growth": None, "cost_usd": None,
                    "seg": {"total": 0, "merged": 0, "done": 0, "park": 0, "open": 0},
                    "live_stages": [], "watch_age_s": None,
                    "run_dir": os.path.join(self.root, name), "ended_at": None,
                    "notes": ["ledger-path 없음"], "hidden": True,
                })
        rows.sort(key=lambda r: (0 if r["band"] == "live" else 1,
                                 r["grade"] if r["band"] == "live" else 0,
                                 -(r["ended_at"] or r["last_growth"] or 0)))
        bases = sorted({s.base for s in self.sources.values() if s.base})
        return {"generated_at": now, "runs": rows, "hidden": hidden, "bases": bases}

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
        return {
            "summary": summary,
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
            "timeline": timeline,
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
        for series, ln in led.rows:
            if series == "stage-result":
                f = split_fields(ln)
                pending = {
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
    print("usage: dashboard_read.py live-stages|live-names <run-dir> | state <run-dir> <ledger> [stall abandon]"
          " | model-state <run-dir> [stall abandon] | grade <token>")
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv[1:]))
