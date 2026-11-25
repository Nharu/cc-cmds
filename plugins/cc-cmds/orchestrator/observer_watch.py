"""observer_watch.py — the observer's `watch` job: the watcher's loop, run as calls.

A looping `watch.sh` on a run that carries the protocol mark hands its arguments
to `observer.py adopt --job watch` and exits. From then on this module decides,
on every observer pass that reaches the job, whether to call the run's pinned
`watch.sh --once` with those arguments, and keeps the two marks a looping
watcher would have kept fresh in between.

WHEN A PASS IS CALLED. On a change of the run directory (the observer's base
probe set plus the probe globs the last pass published in `watch.next`), on the
first tick after adoption or after an observer restart, when the deadline on
the first line of `watch.next` has come, when no pass ran for `MAX_GAP_S`, and
when the gap since this job's previous tick exceeds `STALL_GAP_S` — the host
slept or the observer was held, and the clocks the pass judges on moved without
anything on disk changing. A pass that ran out of its time limit
(`CALL_TIMEOUT_S`) holds every call for `TIMEOUT_BACKOFF_S` but one for a change
the hold lets through, so a run whose pass is slow does not take the observer's
child slots on every tick.

WHAT A HOLD LETS THROUGH. A run whose stages are working changes on every gate
entry: the gate rewrites `started-at` and appends an `자율 승인` row, and its
machine reads append `pace` and `master 판독` rows. Those alone would break the
hold every pass, so right before each call this takes a hold signature — the
observer's own signature of the run without the ledger and `started-at`, and
the ledger's byte size — and during a hold a change calls the pass only when
that signature moved, or the ledger grew by a row of another kind, or shrank.
Taken before the call, it also sees a change made while the slow pass ran.

WHAT IS LOGGED. A timeout line carrying the slots held, load1 and the ledger's
size, and a line for a pass that finished but took `SLOW_PASS_S` or more.

WHAT THE CALL CARRIES. `--started` is the moment the job was adopted (the mtime
of its argument file), which the pass takes as the start of watching for the
day-long idle exit; `--alive-at` is this job's previous tick, which the pass
takes as the last time a watcher saw the run awake for the failover clock. The
observer puts its own pid in `CC_OBSERVER_PID`, and that is what makes the call
a delegated pass.

WHAT THIS WRITES. Between passes, `watch.heartbeat`'s mtime and the epoch of
`watch.mode`, so their readers see a watcher that is alive. Nothing else: no
ledger, no halt record, no sidecar, and no notifier — every judgement and every
banner is the pinned `watch.sh`'s.

Python 3.9 standard library only.
"""

import os
import re
import threading
import time

JOB = "watch"
PID_FILE = "watch.pid"
# `watch.sh` exits with this when a delegated pass finds the run over.
RUN_OVER_RC = 3
MAX_GAP_S = 300
STALL_GAP_S = 10
TIMEOUT_BACKOFF_S = 60
# The observer raises this job's call limit to this, capped by its own maximum.
CALL_TIMEOUT_S = 30
SLOW_PASS_S = 10
# Ledger rows the gate appends on every entry and every machine read; a hold is
# not broken by them alone.
HOLD_QUIET_KINDS = ("자율 승인", "pace", "master 판독")
HOLD_EXCLUDE = ("LEDGER", "started-at")
ROW_RE = re.compile(r"^- `([^`]*)`")

_mem = {}
_mu = threading.Lock()


def _read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(65536).split("\n")
    except OSError:
        return None


def probes(run):
    """The probe globs the last delegated pass published in `watch.next`."""
    lines = _read_lines(os.path.join(run, "watch.next"))
    if not lines:
        return []
    return [ln.strip() for ln in lines[1:] if ln.strip()]


def _deadline(run):
    lines = _read_lines(os.path.join(run, "watch.next"))
    if not lines:
        return None
    first = lines[0].strip()
    return int(first) if first.isdigit() else None


def _started(run):
    try:
        return int(os.stat(os.path.join(run, "observer.jobs", JOB + ".args")).st_mtime)
    except OSError:
        return None


def _keep_marks(run, now):
    hb = os.path.join(run, "watch.heartbeat")
    if os.path.isfile(hb):
        try:
            os.utime(hb, (now, now))
        except OSError:
            pass
    mode = os.path.join(run, "watch.mode")
    lines = _read_lines(mode)
    if not lines:
        return
    words = lines[0].split()
    if not words:
        return
    tmp = os.path.join(run, ".watch.mode.observer.%d" % os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("%s %d\n" % (words[0], int(now)))
        os.replace(tmp, mode)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _size(path):
    if not path:
        return None
    try:
        return os.stat(path).st_size
    except OSError:
        return None


def _hold_base(ctx, run):
    """The hold signature now, or None when the context cannot give one."""
    sig_fn = getattr(ctx, "signature_excluding", None)
    led_fn = getattr(ctx, "ledger_path", None)
    if not callable(sig_fn) or not callable(led_fn):
        return None
    try:
        sig = sig_fn(run, HOLD_EXCLUDE)
        led = led_fn(run)
    except Exception:  # noqa: BLE001 — no signature means no filtering
        return None
    if sig is None:
        return None
    return {"sig": sig, "ledger": led, "size": _size(led)}


def _loud_rows(path, offset):
    """Whether the ledger from `offset` to its end holds a row of a kind outside
    `HOLD_QUIET_KINDS`."""
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except OSError:
        return True
    for line in data.decode("utf-8", "replace").split("\n"):
        m = ROW_RE.match(line)
        if m and m.group(1) not in HOLD_QUIET_KINDS:
            return True
    return False


def _hold_broken(ctx, run, base):
    """Whether a change seen during a hold is one the hold lets through."""
    if base is None:
        return True
    cur = _hold_base(ctx, run)
    if cur is None or cur["sig"] != base["sig"] or cur["ledger"] != base["ledger"]:
        return True
    old, new = base["size"], cur["size"]
    if old is None or new is None:
        return old != new
    if new < old:
        return True
    if new == old:
        return False
    return _loud_rows(cur["ledger"], old)


def _diag(ctx, run):
    """`슬롯 <n>/<상한> load1 <값> 원장 <바이트>B`, `?` for what could not be read."""
    n, cap = "?", "?"
    fn = getattr(ctx, "slots", None)
    if callable(fn):
        try:
            busy, limit = fn()
            n = "?" if busy is None else str(busy)
            cap = str(limit)
        except Exception:  # noqa: BLE001
            pass
    try:
        load = "%.2f" % os.getloadavg()[0]
    except OSError:
        load = "?"
    return "슬롯 %s/%s load1 %s 원장 %sB" % (n, cap, load, _ledger_bytes(ctx, run))


def _ledger_bytes(ctx, run):
    fn = getattr(ctx, "ledger_path", None)
    size = None
    if callable(fn):
        try:
            size = _size(fn(run))
        except Exception:  # noqa: BLE001
            size = None
    return "?" if size is None else str(size)


def tick(ctx, run, changed, now):
    with _mu:
        st = _mem.get(run)
        first = st is None
        if first:
            st = _mem[run] = {"last_call": None, "last_tick": None, "hold_until": 0.0,
                              "hold_base": None}
        prev_tick = st["last_tick"]
        st["last_tick"] = now

    due = changed or first
    if not due and (st["last_call"] is None or now - st["last_call"] >= MAX_GAP_S):
        due = True
    if not due:
        d = _deadline(run)
        if d is not None and d <= now:
            due = True
    if not due and prev_tick is not None and now - prev_tick > STALL_GAP_S:
        due = True
    if now < st["hold_until"]:
        due = changed and _hold_broken(ctx, run, st["hold_base"])

    if due:
        argv = ["watch.sh", "--once"]
        started = _started(run)
        if started is not None:
            argv += ["--started", str(started)]
        if prev_tick is not None:
            argv += ["--alive-at", str(int(prev_tick))]
        argv += ctx.args(run)
        st["last_call"] = now
        st["hold_base"] = _hold_base(ctx, run)
        t0 = time.monotonic()
        rc, _ = ctx.call(run, argv, timeout=CALL_TIMEOUT_S)
        took = time.monotonic() - t0
        if rc >= 0 and took >= SLOW_PASS_S:
            ctx.log("watch.sh 느린 판 %s %.1f초 원장 %sB" % (run, took, _ledger_bytes(ctx, run)))
        if rc == RUN_OVER_RC:
            ctx.drop(run)
            with _mu:
                _mem.pop(run, None)
            return None
        if rc < 0:
            ctx.log("watch.sh 시한 초과 %s — %d초 동안 변화에만 부른다 %s"
                    % (run, TIMEOUT_BACKOFF_S, _diag(ctx, run)))
            st["hold_until"] = now + TIMEOUT_BACKOFF_S
        elif rc != 0:
            ctx.log("watch.sh 종료 코드 %d %s" % (rc, run))

    _keep_marks(run, now)
    return now + 1.0
