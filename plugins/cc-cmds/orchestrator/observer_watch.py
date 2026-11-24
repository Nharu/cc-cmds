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
anything on disk changing. A pass that ran out of the observer's time limit
holds every call but a change's for `TIMEOUT_BACKOFF_S`, so a run whose pass is
slow does not take the observer's child slots on every tick.

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
import threading

JOB = "watch"
PID_FILE = "watch.pid"
# `watch.sh` exits with this when a delegated pass finds the run over.
RUN_OVER_RC = 3
MAX_GAP_S = 300
STALL_GAP_S = 10
TIMEOUT_BACKOFF_S = 60

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


def tick(ctx, run, changed, now):
    with _mu:
        st = _mem.get(run)
        first = st is None
        if first:
            st = _mem[run] = {"last_call": None, "last_tick": None, "hold_until": 0.0}
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
    if not changed and now < st["hold_until"]:
        due = False

    if due:
        argv = ["watch.sh", "--once"]
        started = _started(run)
        if started is not None:
            argv += ["--started", str(started)]
        if prev_tick is not None:
            argv += ["--alive-at", str(int(prev_tick))]
        argv += ctx.args(run)
        st["last_call"] = now
        rc, _ = ctx.call(run, argv)
        if rc == RUN_OVER_RC:
            ctx.drop(run)
            with _mu:
                _mem.pop(run, None)
            return None
        if rc < 0:
            ctx.log("watch.sh 시한 초과 %s — %d초 동안 변화에만 부른다" % (run, TIMEOUT_BACKOFF_S))
            st["hold_until"] = now + TIMEOUT_BACKOFF_S
        elif rc != 0:
            ctx.log("watch.sh 종료 코드 %d %s" % (rc, run))

    _keep_marks(run, now)
    return now + 1.0
