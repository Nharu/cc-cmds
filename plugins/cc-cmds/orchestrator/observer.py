"""observer.py — the resident observer: one process that watches every adopted run.

    python3 observer.py ensure [--sl-session <sid> --sl-script <path> --sl-transcript <path>]
                               [--pane-session <sid> --pane-script <path> --pane-index <path>]
                                     start the observer unless one of ours is up
    python3 observer.py status       one line: off | absent | hung | running
    python3 observer.py stop         stop the recorded observer, identity checked
    python3 observer.py adopt --run-dir <RUN_DIR> --job <job> -- <the job's own arguments...>
                                     hand one job of one run to the observer; 0 only
                                     when the observer wrote its pid into the job's pid file
    python3 observer.py serve        the observer itself; started by `ensure` only

THE LIFECYCLE IS `dashboard.py`'S. A record file written through a temporary
file and a rename, a lock directory with a holder pid and fingerprint, a judge
that answers `ours`, `hung` or `none`, and an `ensure` that replaces a live
observer only when its own plugin version is the higher one. Beside the record
sits `observer.pid`, the bare pid on one line, so that a shell can read it with
the `read` builtin; and `heartbeat`, which every pass rewrites with the epoch
of that pass, so that a stopped observer is told from a live one by age alone —
by its mtime here, and by its one line in a shell that has no `stat` builtin.

WHAT THE OBSERVER LOOKS AT IS VERSION-FREE. File mtimes and sizes and whether a
pid answers mean the same thing to every plugin version, so one observer can
watch runs pinned at several. Every judgement is made by the run's own pinned
scripts, which a job module calls through `ctx.call`.

WHO WRITES WHAT. The observer writes its own state directory, the `observer.*`
files and the adopted jobs' pid files inside an adopted run, and the usage mark
`observer.code-inuse` of the pinned copy it runs from. It never writes a
ledger, a halt record, an approval sidecar, `pipeline-grant` or `pipeline-run`,
and it never calls a notifier or `notify-run.sh`.

`ensure` ALWAYS EXITS 0. It is called from the status line and the run pane on
a render, and from a watcher that is about to delegate; none of them may fail
because the observer could not start.

Python 3.9 standard library only.
"""

import sys

sys.dont_write_bytecode = True

import errno  # noqa: E402
import fcntl  # noqa: E402
import glob  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import secrets  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import stat  # noqa: E402
import struct  # noqa: E402
import subprocess  # noqa: E402
import termios  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(HERE)

SCHEMA = 1
PROTOCOL = "observer-protocol 1"
LOCK_ORPHAN_S = 10
STOP_WAIT_S = 5.0
ADOPT_WAIT_S = 10.0
ADOPT_POLL_S = 0.2
CHILD_LIMIT = 4
CHILD_TIMEOUT_S = 10.0
LOG_CAP = 1 << 20
DEFAULT_PERIOD = 2.0
DEFAULT_GRACE = 300.0
DEFAULT_HUNG_AFTER = 30.0
SUPERSEDE_AFTER_S = 5.0
FAILED_RETRY_S = 10.0

RID_RE = re.compile(r"^[0-9]{8}-[0-9a-f]{8}$")
SID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
JOB_RE = re.compile(r"^[a-z]+$")
MODULE_RE = re.compile(r"^observer_([a-z]+)\.py$")
SCRIPT_RE = re.compile(r"^[a-z][a-z0-9_-]*\.sh$")

# The watcher's own probe set (`WATCH_PROBES` in watch.sh), as the observer reads
# it. `LEDGER` is the file `ledger-path` names; a trailing `/` is a directory
# whose listing is compared.
BASE_PROBES = ("LEDGER", "halt/", "halt/shift/", "started-at", "done", "ends-on-done",
               "shift.live", "relay.live", "*.pid", "*.sup", "*.waiting", "*.sup.start",
               "*.pid.settling*", "apply/*.launch", "apply/*.sup", "apply/*.sup.start",
               "apply/*.sup.self", "apply/*.sup.self.start")
# Written by the delegated jobs and by the observer itself on every pass, so they
# are never a change: passed over by name, as watch.sh passes over them.
SELF_WRITTEN = ("watch.pid", "checks.pid", "checks.observed")

# The input keys each registered kind is computed with. The status line reads
# `session_id` and `transcript_path` from stdin and these from its environment.
SL_KEYS = ("CLAUDE_CONFIG_DIR", "XDG_STATE_HOME", "HOME", "CC_CMDS_AUTOPILOT_TZ",
           "CC_SL_SCREEN", "CC_SL_PANE_FIELDS", "CC_SL_TRACE")
PANE_KEYS = ("CC_CMDS_AUTOPILOT_TZ", "XDG_STATE_HOME", "HOME", "CLAUDE_CONFIG_DIR")
KINDS = {
    "sl": {"script": "statusline.sh", "head": "cc-sl-facts 1", "var": "CC_SL_FACTS_OUT",
           "keys": SL_KEYS, "extra": "transcript"},
    "pane": {"script": "run-pane.sh", "head": "cc-pane-facts 1", "var": "CC_PANE_FACTS_OUT",
             "keys": PANE_KEYS, "extra": "index"},
}
CHILD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


# ---------------------------------------------------------------------------
# Paths and small readers
# ---------------------------------------------------------------------------

def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")


def state_root():
    return os.path.join(state_home(), "cc-cmds")


def run_root():
    return os.path.join(state_root(), "run")


def session_dir():
    return os.path.join(state_root(), "session")


def obs_dir():
    return os.path.join(state_root(), "observer")


def obs_path(*parts):
    return os.path.join(obs_dir(), *parts)


def env_float(name, default):
    try:
        v = float(os.environ.get(name, ""))
        if v > 0:
            return v
    except ValueError:
        pass
    return default


def hung_after():
    return env_float("CC_OBSERVER_HUNG_AFTER", DEFAULT_HUNG_AFTER)


def plugin_version(code_dir=HERE):
    path = os.path.join(os.path.dirname(code_dir), ".claude-plugin", "plugin.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return str(json.load(f).get("version", "0.0.0"))
    except (OSError, ValueError, AttributeError):
        return "0.0.0"


def semver(v):
    core = str(v or "").split("-", 1)[0].split("+", 1)[0]
    out = []
    for part in core.split(".")[:3]:
        try:
            out.append(int(part))
        except ValueError:
            out.append(0)
    while len(out) < 3:
        out.append(0)
    return tuple(out)


def fingerprint(pid):
    """`LC_ALL=C ps -o lstart= -p <pid>`, whitespace normalised as liveness.sh does."""
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(int(pid))], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=5)
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    return " ".join(r.stdout.decode("utf-8", "replace").split())


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError, OverflowError, TypeError):
        return False
    return True


def same_process(pid, fp):
    return bool(fp) and pid_alive(pid) and fingerprint(pid) == fp


def read_text(path, limit=65536):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


def read_int(path):
    t = read_text(path, 256)
    if t is None:
        return None
    t = "".join(t.split())
    return int(t) if t.isdigit() else None


def write_atomic(path, data, mode=0o600):
    if isinstance(data, str):
        data = data.encode("utf-8")
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".%s.tmp.%d.%s" % (os.path.basename(path), os.getpid(), secrets.token_hex(3)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        try:
            view = memoryview(data)
            while view:
                n = os.write(fd, view)
                view = view[n:]
        finally:
            os.close(fd)
        os.chmod(tmp, mode)
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def unlink_quiet(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def touch(path):
    """Refresh the mtime, creating the file (0600) when it is missing."""
    try:
        os.utime(path, None)
    except FileNotFoundError:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
        os.close(fd)
    except OSError:
        pass


def beat():
    """Refresh `heartbeat`: its mtime for this file's own readers, and the same
    epoch as its one line, so that a status line can age it with the `read`
    builtin instead of a `stat` process."""
    try:
        write_atomic(obs_path("heartbeat"), "%d\n" % int(time.time()))
    except OSError:
        pass


def make_dir(path, mode=0o700):
    os.makedirs(path, mode, exist_ok=True)
    os.chmod(path, mode)


def mtime_of(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def read_record():
    try:
        with open(obs_path("record.json"), "r", encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(rec, dict) or rec.get("schema") != SCHEMA:
        return None
    try:
        rec["pid"] = int(rec["pid"])
    except (KeyError, TypeError, ValueError):
        return None
    return rec


def heartbeat_age(now=None):
    now = time.time() if now is None else now
    t = mtime_of(obs_path("heartbeat"))
    if t is None:
        t = mtime_of(obs_path("record.json"))
    return float("inf") if t is None else now - t


def judge(rec):
    """`ours` (with the observer's version), `hung`, or `none`.

    `hung` is a recorded process that is still the recorded process but whose
    heartbeat is older than `CC_OBSERVER_HUNG_AFTER` — a stopped or wedged
    observer, which `ensure` replaces as it replaces a missing one.
    """
    if rec is None or not same_process(rec["pid"], rec.get("fingerprint", "")):
        return "none", None
    if heartbeat_age() > hung_after():
        return "hung", None
    return "ours", str(rec.get("version", "0.0.0"))


# ---------------------------------------------------------------------------
# Switches and the trust boundary
# ---------------------------------------------------------------------------

def switched_off():
    return os.environ.get("CC_CMDS_OBSERVER", "") == "off" or bool(os.environ.get("CI"))


def in_stage():
    return bool(os.environ.get("CC_PIPELINE_SEGMENT") or os.environ.get("CC_PIPELINE_STAGE_ID"))


def sid_ok(sid):
    return bool(sid) and bool(SID_RE.match(sid)) and sid.strip(".") != ""


def run_dir_ok(rd):
    """A directory directly under the run root, not a link, at its own physical
    place, whose `plugin/cc-cmds` resolves inside it — `pin_hop_target`'s rule."""
    if not rd or not os.path.isabs(rd):
        return False
    rd = rd.rstrip("/")
    name = os.path.basename(rd)
    if name in ("", ".", ".."):
        return False
    rr = os.path.realpath(run_root())
    if os.path.realpath(os.path.dirname(rd)) != rr:
        return False
    if os.path.islink(rd) or not os.path.isdir(rd):
        return False
    rdp = os.path.realpath(rd)
    if rdp != os.path.join(rr, name):
        return False
    pp = os.path.realpath(os.path.join(rd, "plugin", "cc-cmds"))
    return pp.startswith(rdp + "/")


def protocol_ok(rd):
    t = read_text(os.path.join(rd, "plugin", "cc-cmds", "orchestrator", "observer-protocol"), 4096)
    return t is not None and t.split("\n", 1)[0] == PROTOCOL


def script_ok(path, name):
    """`<name>` in this observer's own `orchestrator/`, or in a run's pinned copy."""
    if not path or not os.path.isabs(path) or os.path.basename(path) != name:
        return False
    real = os.path.realpath(path)
    if os.path.basename(real) != name or not os.path.isfile(real):
        return False
    d = os.path.dirname(real)
    if d == os.path.realpath(HERE):
        return True
    rr = os.path.realpath(run_root())
    m = re.match(re.escape(rr) + r"/([^/]+)/plugin/cc-cmds/orchestrator$", d)
    return bool(m) and m.group(1) not in (".", "..")


def index_ok(path):
    if not path or not os.path.isabs(path):
        return False
    real = os.path.realpath(path)
    if os.path.dirname(real) != os.path.realpath(session_dir()):
        return False
    try:
        return stat.S_ISREG(os.stat(real).st_mode)
    except OSError:
        return False


def load_modules():
    """Every `observer_<job>.py` in this observer's own `orchestrator/`, by path."""
    mods = {}
    try:
        names = sorted(os.listdir(HERE))
    except OSError:
        return mods
    for name in names:
        m = MODULE_RE.match(name)
        if not m:
            continue
        path = os.path.join(HERE, name)
        if not os.path.isfile(path):
            continue
        try:
            spec = importlib.util.spec_from_file_location("cc_observer_" + m.group(1), path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:  # noqa: BLE001 — a broken module is skipped, not fatal
            log("모듈 적재 실패 %s: %s" % (name, e))
            continue
        job = getattr(mod, "JOB", None)
        pidf = getattr(mod, "PID_FILE", None)
        if job != m.group(1) or not isinstance(pidf, str) or not pidf or "/" in pidf:
            continue
        if not callable(getattr(mod, "probes", None)) or not callable(getattr(mod, "tick", None)):
            continue
        mods[job] = mod
    return mods


def child_env(extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CC_PIPELINE_")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if extra:
        env.update(extra)
    return env


def log(msg):
    try:
        sys.stdout.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
        sys.stdout.flush()
    except (OSError, ValueError):
        pass


# ---------------------------------------------------------------------------
# Lock, stop, spawn — dashboard.py's shapes
# ---------------------------------------------------------------------------

def take_lock():
    """mkdir the lock; reclaim it from a dead holder by renaming it aside."""
    d = obs_path("lock")
    for attempt in (0, 1):
        try:
            os.mkdir(d, 0o700)
        except FileExistsError:
            if attempt or not lock_holder_dead(d):
                return False
            aside = "%s.stale.%d.%s" % (d, os.getpid(), secrets.token_hex(4))
            try:
                os.rename(d, aside)
            except OSError:
                return False
            shutil.rmtree(aside, ignore_errors=True)
            continue
        except OSError:
            return False
        try:
            tmp = os.path.join(d, ".holder.tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("%d\n%s\n" % (os.getpid(), fingerprint(os.getpid())))
            os.rename(tmp, os.path.join(d, "holder"))
        except OSError:
            shutil.rmtree(d, ignore_errors=True)
            return False
        return True
    return False


def lock_holder_dead(d):
    try:
        with open(os.path.join(d, "holder"), "r", encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError:
        try:
            return time.time() - os.stat(d).st_mtime > LOCK_ORPHAN_S
        except OSError:
            return False
    try:
        pid = int(lines[0])
    except (ValueError, IndexError):
        return True
    fp = lines[1] if len(lines) > 1 else ""
    return not same_process(pid, fp)


def release_lock():
    shutil.rmtree(obs_path("lock"), ignore_errors=True)


def stop_process(pid, fp):
    """SIGTERM a confirmed process, wait up to 5 s, then SIGKILL. True when it is gone."""
    if not same_process(pid, fp):
        return True
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return not pid_alive(pid)
    deadline = time.monotonic() + STOP_WAIT_S
    while time.monotonic() < deadline:
        if not same_process(pid, fp):
            return True
        time.sleep(0.05)
    if same_process(pid, fp):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            if not same_process(pid, fp):
                return True
            time.sleep(0.05)
    return not same_process(pid, fp)


def spawn():
    """Double fork and setsid, as dashboard.py's `spawn`. Returns the grandchild pid."""
    logf = obs_path("observer.log")
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(r)
            try:
                os.setsid()
            except OSError:
                pass
            gpid = os.fork()
            if gpid == 0:
                os.close(w)
                try:
                    os.setsid()
                except OSError:
                    pass
                os.chdir("/")
                fd_in = os.open("/dev/null", os.O_RDONLY)
                fd_log = os.open(logf, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                os.dup2(fd_in, 0)
                os.dup2(fd_log, 1)
                os.dup2(fd_log, 2)
                # Nothing the caller held open may outlive it in the observer: a
                # status line's harness reads its pipe to the end.
                os.closerange(3, 65536)
                env = child_env()
                env["PATH"] = "/usr/bin:/bin" + (":" + env["PATH"] if env.get("PATH") else "")
                os.execve(sys.executable, [sys.executable, os.path.abspath(__file__), "serve"], env)
            os.write(w, b"%d\n" % gpid)
        except BaseException:
            pass
        finally:
            os._exit(0)
    os.close(w)
    data = b""
    while True:
        chunk = os.read(r, 64)
        if not chunk:
            break
        data += chunk
    os.close(r)
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    try:
        return int(data.strip())
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# ensure / status / stop
# ---------------------------------------------------------------------------

def parse_ensure(argv):
    opts = {}
    names = ("--sl-session", "--sl-script", "--sl-transcript",
             "--pane-session", "--pane-script", "--pane-index")
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in names and i + 1 < len(argv):
            opts[a[2:].replace("-", "_")] = argv[i + 1]
            i += 2
        else:
            return None
    return opts


def register(opts):
    """Write the session registrations `ensure` was handed, after checking them."""
    for kind, prefix in (("sl", "sl_"), ("pane", "pane_")):
        sid = opts.get(prefix + "session", "")
        if not sid:
            continue
        k = KINDS[kind]
        if kind == "sl" and os.environ.get("CC_SL_PANE_FIELDS", ""):
            continue
        script = opts.get(prefix + "script", "")
        extra = opts.get(prefix + k["extra"], "")
        if not sid_ok(sid) or not script_ok(script, k["script"]):
            continue
        if kind == "pane" and not index_ok(extra):
            continue
        try:
            cwd = os.getcwd()
        except OSError:
            cwd = "/"
        pairs = [("script", script), ("sid", sid), (k["extra"], extra), ("cwd", cwd)]
        for name in k["keys"]:
            if name in os.environ:
                pairs.append(("env." + name, os.environ[name]))
        if any("\n" in v or "\r" in v for _, v in pairs):
            continue
        d = obs_path(kind)
        make_dir(d)
        write_atomic(os.path.join(d, sid + ".reg"), "".join("%s=%s\n" % kv for kv in pairs))


def write_record(gpid, mine):
    write_atomic(obs_path("record.json"), json.dumps({
        "schema": SCHEMA, "pid": gpid, "fingerprint": fingerprint(gpid),
        "version": mine, "root": os.path.realpath(CODE_ROOT),
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, sort_keys=True) + "\n")
    write_atomic(obs_path("observer.pid"), "%d\n" % gpid)
    beat()


def ensure_daemon():
    mine = plugin_version()
    verdict, theirs = judge(read_record())
    if verdict == "ours" and semver(mine) <= semver(theirs):
        return 0
    if not take_lock():
        return 0
    try:
        rec = read_record()
        verdict, theirs = judge(rec)
        if verdict == "ours" and semver(mine) <= semver(theirs):
            return 0
        if verdict in ("ours", "hung"):
            if not stop_process(rec["pid"], rec.get("fingerprint", "")):
                return 0
        gpid = spawn()
        if gpid is None:
            return 0
        try:
            write_record(gpid, mine)
        except OSError:
            try:
                os.kill(gpid, signal.SIGTERM)
            except OSError:
                pass
        return 0
    finally:
        release_lock()


def ensure(opts):
    """Steps in order: switch, stage, `ensure.at`, registration, judge, start."""
    if switched_off() or in_stage():
        return 0
    try:
        make_dir(obs_dir())
        write_atomic(obs_path("ensure.at"), "%d\n" % int(time.time()))
    except OSError:
        return 0
    try:
        if opts:
            register(opts)
    except Exception:  # noqa: BLE001 — ensure never fails
        pass
    try:
        return ensure_daemon()
    except Exception:  # noqa: BLE001
        return 0


def status():
    if switched_off():
        print("off")
        return 0
    rec = read_record()
    if rec is None or not same_process(rec["pid"], rec.get("fingerprint", "")):
        print("absent")
    elif heartbeat_age() > hung_after():
        print("hung")
    else:
        print("running")
    return 0


def stop():
    rec = read_record()
    got = False
    deadline = time.monotonic() + 2.0
    while not got and time.monotonic() < deadline and os.path.isdir(obs_dir()):
        got = take_lock()
        if not got:
            time.sleep(0.1)
    try:
        if rec is not None:
            stop_process(rec["pid"], rec.get("fingerprint", ""))
        unlink_quiet(obs_path("record.json"))
        unlink_quiet(obs_path("observer.pid"))
    finally:
        if got:
            release_lock()
    return 0


# ---------------------------------------------------------------------------
# adopt (the caller's side)
# ---------------------------------------------------------------------------

def adopt(argv):
    rd = job = None
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--run-dir" and i + 1 < len(argv):
            rd = argv[i + 1]
            i += 2
        elif a == "--job" and i + 1 < len(argv):
            job = argv[i + 1]
            i += 2
        elif a == "--":
            args = argv[i + 1:]
            break
        else:
            sys.stderr.write("observer adopt: 알 수 없는 인자 %s\n" % a)
            return 2
    if switched_off():
        sys.stderr.write("observer adopt: 끄기 스위치\n")
        return 1
    if in_stage():
        sys.stderr.write("observer adopt: 스테이지 환경\n")
        return 1
    if not rd or not job or not JOB_RE.match(job):
        sys.stderr.write("observer adopt: --run-dir 와 --job 이 필요하다\n")
        return 2
    mods = load_modules()
    if job not in mods:
        sys.stderr.write("observer adopt: 모르는 작업 %s\n" % job)
        return 2
    rd = rd.rstrip("/")
    if not run_dir_ok(rd):
        sys.stderr.write("observer adopt: 런 루트 밖이거나 심볼릭 링크인 런 디렉터리\n")
        return 2
    if not protocol_ok(rd):
        sys.stderr.write("observer adopt: 규약 표지가 없거나 모르는 판본\n")
        return 2
    if any("\n" in a for a in args):
        sys.stderr.write("observer adopt: 개행이 든 인자\n")
        return 2
    jd = os.path.join(rd, "observer.jobs")
    argsf = os.path.join(jd, job + ".args")
    try:
        make_dir(jd)
        write_atomic(argsf, "".join(a + "\n" for a in args))
    except OSError as e:
        sys.stderr.write("observer adopt: 인자 기록 실패 %s\n" % e)
        return 1
    ensure({})
    ad = obs_path("adopt.d")
    req = os.path.join(ad, "%s.%s" % (os.path.basename(rd), job))
    try:
        make_dir(ad)
        unlink_quiet(req + ".no")
        write_atomic(req, rd + "\n")
    except OSError as e:
        unlink_quiet(argsf)
        sys.stderr.write("observer adopt: 요청 기록 실패 %s\n" % e)
        return 1
    pidf = os.path.join(rd, mods[job].PID_FILE)
    deadline = time.monotonic() + ADOPT_WAIT_S
    while True:
        dpid = read_int(obs_path("observer.pid"))
        if dpid and read_int(pidf) == dpid and pid_alive(dpid):
            return 0
        if os.path.exists(req + ".no"):
            reason = (read_text(req + ".no", 4096) or "").strip()
            unlink_quiet(req + ".no")
            sys.stderr.write("observer adopt: 거절 — %s\n" % (reason or "사유 없음"))
            return 1
        if time.monotonic() >= deadline:
            break
        time.sleep(ADOPT_POLL_S)
    # Given up: the caller now runs its own loop, so nothing may make the
    # observer claim this job behind it.
    unlink_quiet(req)
    unlink_quiet(argsf)
    sys.stderr.write("observer adopt: 시한 안에 채택되지 않았다\n")
    return 1


# ---------------------------------------------------------------------------
# The observer
# ---------------------------------------------------------------------------

class Job:
    def __init__(self, args):
        self.args = list(args)
        self.deadline = None
        self.pending = True
        self.thread = None


class Run:
    def __init__(self, rd):
        self.rd = rd
        self.jobs = {}
        self.sig = None


class Ctx:
    """What a job module is handed. Bound to one job."""

    def __init__(self, daemon, job):
        self._d = daemon
        self.job = job
        self.pid = daemon.pid

    def call(self, run, argv, timeout=CHILD_TIMEOUT_S):
        """Run one of the run's pinned scripts: (rc, stdout)."""
        if not argv or not SCRIPT_RE.match(str(argv[0])) or not run_dir_ok(run):
            return 127, ""
        path = os.path.join(run, "plugin", "cc-cmds", "orchestrator", argv[0])
        if not os.path.isfile(path):
            return 127, ""
        try:
            t = min(float(timeout), CHILD_TIMEOUT_S)
        except (TypeError, ValueError):
            t = CHILD_TIMEOUT_S
        env = child_env({"CC_OBSERVER_PID": str(self._d.pid)})
        try:
            p = subprocess.Popen(["bash", path] + [str(a) for a in argv[1:]], env=env, cwd="/",
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            return 127, ""
        self._d.track(p)
        try:
            out, _ = p.communicate(timeout=t)
        except subprocess.TimeoutExpired:
            kill_group(p)
            try:
                p.communicate(timeout=2)
            except subprocess.SubprocessError:
                pass
            return -signal.SIGKILL, ""
        finally:
            self._d.untrack(p)
        return p.returncode, out.decode("utf-8", "replace")

    def drop(self, run):
        self._d.request_drop(run, self.job)

    def args(self, run):
        r = self._d.runs.get(run)
        j = r.jobs.get(self.job) if r else None
        return list(j.args) if j else []

    def log(self, msg):
        log("[%s] %s" % (self.job, msg))


def kill_group(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        try:
            p.kill()
        except OSError:
            pass


class Daemon:
    def __init__(self):
        self.pid = os.getpid()
        self.started = time.monotonic()
        self.period = env_float("CC_OBSERVER_PERIOD", DEFAULT_PERIOD)
        self.grace = env_float("CC_OBSERVER_GRACE", DEFAULT_GRACE)
        self.mods = load_modules()
        self.runs = {}
        self.facts = {}        # (kind, sid) -> {"sig", "retry"}
        self.children = []     # recompute children
        self.batches = {}      # job -> thread
        self.drops = []
        self.live = set()
        self.mu = threading.Lock()
        self.stopping = False
        self.idle_since = time.monotonic()
        self.inuse = None
        skip = set(SELF_WRITTEN)
        for m in self.mods.values():
            skip.add(m.PID_FILE)
        self.skip = skip

    # -- bookkeeping -------------------------------------------------------

    def track(self, p):
        with self.mu:
            self.live.add(p)

    def untrack(self, p):
        with self.mu:
            self.live.discard(p)

    def request_drop(self, rd, job):
        with self.mu:
            self.drops.append((rd, job))

    def busy(self):
        n = len(self.children)
        for run in self.runs.values():
            for j in run.jobs.values():
                if j.thread is not None and j.thread.is_alive():
                    n += 1
        for t in self.batches.values():
            if t.is_alive():
                n += 1
        return n

    # -- start and end -----------------------------------------------------

    def start(self):
        make_dir(obs_dir())
        beat()
        self.write_inuse()
        self.restore()
        log("관측기 기동 pid=%d 판본=%s 모듈=%s" % (self.pid, plugin_version(), ",".join(sorted(self.mods))))

    def write_inuse(self):
        cr = os.path.realpath(CODE_ROOT)
        rr = os.path.realpath(run_root())
        m = re.match(re.escape(rr) + r"/([^/]+)/plugin/cc-cmds$", cr)
        if not m or m.group(1) in (".", ".."):
            return
        path = os.path.join(rr, m.group(1), "observer.code-inuse")
        try:
            write_atomic(path, "pid=%d\nfingerprint=%s\n" % (self.pid, fingerprint(self.pid)))
            self.inuse = path
        except OSError:
            self.inuse = None

    def shutdown(self):
        with self.mu:
            live = list(self.live)
        for p in live:
            kill_group(p)
        for c in self.children:
            kill_group(c["p"])
            unlink_quiet(c["out"])
        for run in self.runs.values():
            for job in run.jobs:
                pidf = os.path.join(run.rd, self.mods[job].PID_FILE)
                if read_int(pidf) == self.pid:
                    unlink_quiet(pidf)
        rec = read_record()
        if rec is not None and rec["pid"] == self.pid:
            unlink_quiet(obs_path("record.json"))
        if read_int(obs_path("observer.pid")) == self.pid:
            unlink_quiet(obs_path("observer.pid"))
        if self.inuse:
            t = read_text(self.inuse, 4096) or ""
            if ("pid=%d\n" % self.pid) in t:
                unlink_quiet(self.inuse)
        log("관측기 종료 pid=%d" % self.pid)

    def restore(self):
        """Re-adopt from the session indexes: runs with `.args`, the mark and no `done`."""
        try:
            names = sorted(os.listdir(session_dir()))
        except OSError:
            return
        rids = []
        for name in names:
            p = os.path.join(session_dir(), name)
            try:
                if not stat.S_ISREG(os.lstat(p).st_mode):
                    continue
            except OSError:
                continue
            for line in (read_text(p) or "").split("\n"):
                line = line.strip()
                if RID_RE.match(line) and line not in rids:
                    rids.append(line)
        for rid in rids:
            rd = os.path.join(run_root(), rid)
            if not run_dir_ok(rd) or not protocol_ok(rd) or os.path.exists(os.path.join(rd, "done")):
                continue
            try:
                files = sorted(os.listdir(os.path.join(rd, "observer.jobs")))
            except OSError:
                continue
            for f in files:
                if not f.endswith(".args"):
                    continue
                job = f[:-5]
                if job not in self.mods:
                    continue
                text = read_text(os.path.join(rd, "observer.jobs", f))
                if text is None:
                    continue
                args = text.split("\n")
                if args and args[-1] == "":
                    args.pop()
                self.adopt_run(rd, job, args, "복원")

    # -- adoption ----------------------------------------------------------

    def adopt_run(self, rd, job, args, why):
        try:
            make_dir(os.path.join(rd, "observer.wake.d"))
            write_atomic(os.path.join(rd, self.mods[job].PID_FILE), "%d" % self.pid)
        except OSError as e:
            log("채택 실패 %s %s: %s" % (rd, job, e))
            return False
        run = self.runs.get(rd)
        if run is None:
            run = self.runs[rd] = Run(rd)
        j = run.jobs.get(job)
        if j is None:
            run.jobs[job] = Job(args)
        else:
            j.args = list(args)
            j.pending = True
        log("채택(%s) %s %s" % (why, rd, job))
        return True

    def take_requests(self):
        ad = obs_path("adopt.d")
        try:
            names = sorted(os.listdir(ad))
        except OSError:
            return
        for name in names:
            if name.startswith(".") or name.endswith(".no"):
                continue
            path = os.path.join(ad, name)
            rid, _, job = name.rpartition(".")
            rd = (read_text(path, 4096) or "").split("\n", 1)[0].rstrip("/")
            unlink_quiet(path)
            reason = self.refusal(rd, rid, job)
            if reason is None:
                text = read_text(os.path.join(rd, "observer.jobs", job + ".args"))
                if text is None:
                    reason = "인자 파일이 없다"
                else:
                    args = text.split("\n")
                    if args and args[-1] == "":
                        args.pop()
                    if not self.adopt_run(rd, job, args, "요청"):
                        reason = "pid 파일을 쓰지 못했다"
            if reason is not None:
                try:
                    write_atomic(path + ".no", reason + "\n")
                except OSError:
                    pass

    def refusal(self, rd, rid, job):
        if not JOB_RE.match(job or "") or job not in self.mods:
            return "모르는 작업"
        if not run_dir_ok(rd) or os.path.basename(rd) != rid:
            return "런 디렉터리가 신뢰 경계 밖이다"
        if not protocol_ok(rd):
            return "규약 표지가 없거나 모르는 판본"
        return None

    def apply_drops(self):
        with self.mu:
            drops, self.drops = self.drops, []
        for rd, job in drops:
            self.drop(rd, job)

    def drop(self, rd, job):
        run = self.runs.get(rd)
        if run is None or job not in run.jobs:
            return
        del run.jobs[job]
        unlink_quiet(os.path.join(rd, "observer.jobs", job + ".args"))
        pidf = os.path.join(rd, self.mods[job].PID_FILE)
        if read_int(pidf) == self.pid:
            unlink_quiet(pidf)
        if not run.jobs:
            del self.runs[rd]
        log("내려놓음 %s %s" % (rd, job))

    # -- observing ---------------------------------------------------------

    def probes_of(self, run):
        globs = list(BASE_PROBES)
        for job in run.jobs:
            try:
                extra = self.mods[job].probes(run.rd)
            except Exception:  # noqa: BLE001
                extra = []
            for g in extra or []:
                if isinstance(g, str) and g and not g.startswith("/") and ".." not in g.split("/") \
                        and g not in globs:
                    globs.append(g)
        return globs

    def signature(self, run):
        rd = run.rd
        items = []
        seen = set()
        for g in self.probes_of(run):
            if g == "LEDGER":
                led = (read_text(os.path.join(rd, "ledger-path"), 4096) or "").split("\n", 1)[0]
                if led and os.path.isabs(led):
                    items.append(("LEDGER", stat_sig(led)))
                continue
            if g.endswith("/"):
                items.append((g, dir_sig(os.path.join(rd, g))))
                continue
            for p in sorted(glob.glob(os.path.join(rd, g))):
                rel = os.path.relpath(p, rd)
                if rel in seen or os.path.basename(p) in self.skip:
                    continue
                seen.add(rel)
                if rel == "relay.live":
                    items.append((rel, relay_sig(p)))
                    continue
                items.append((rel, stat_sig(p)))
                if p.endswith(".pid"):
                    items.append((rel, "alive", pid_alive(read_int(p))))
        return tuple(items)

    def observe(self, run, now):
        if not os.path.isdir(run.rd):
            for job in list(run.jobs):
                self.drop(run.rd, job)
            return
        sig = self.signature(run)
        changed = run.sig is not None and sig != run.sig
        run.sig = sig
        self.reap_fifos(run)
        if changed:
            touch(os.path.join(run.rd, "observer.wake"))
            self.wake_fifos(run)
        for job, j in list(run.jobs.items()):
            if changed:
                j.pending = True
            due = j.pending or (j.deadline is not None and now >= j.deadline)
            if not due or (j.thread is not None and j.thread.is_alive()):
                continue
            if self.busy() >= CHILD_LIMIT:
                continue
            was = j.pending
            j.pending = False
            j.thread = threading.Thread(target=self.run_tick, args=(run.rd, job, j, was, now), daemon=True)
            j.thread.start()

    def run_tick(self, rd, job, j, changed, now):
        try:
            res = self.mods[job].tick(Ctx(self, job), rd, changed, now)
            j.deadline = float(res) if res is not None else None
        except Exception as e:  # noqa: BLE001
            log("tick 실패 %s %s: %s" % (rd, job, e))
            j.deadline = now + 60

    def batch(self, now):
        for job, mod in self.mods.items():
            fn = getattr(mod, "batch", None)
            if not callable(fn):
                continue
            runs = [rd for rd, r in self.runs.items() if job in r.jobs]
            if not runs:
                continue
            t = self.batches.get(job)
            if (t is not None and t.is_alive()) or self.busy() >= CHILD_LIMIT:
                continue

            def work(fn=fn, job=job, runs=runs):
                try:
                    fn(Ctx(self, job), runs, now)
                except Exception as e:  # noqa: BLE001
                    log("batch 실패 %s: %s" % (job, e))
            t = threading.Thread(target=work, daemon=True)
            self.batches[job] = t
            t.start()

    def reap_fifos(self, run):
        wd = os.path.join(run.rd, "observer.wake.d")
        try:
            names = os.listdir(wd)
        except OSError:
            return
        for name in names:
            if not name.endswith(".fifo"):
                continue
            owner = name[:-5].rpartition(".")[2]
            if owner.isdigit() and not pid_alive(int(owner)):
                unlink_quiet(os.path.join(wd, name))

    def wake_fifos(self, run):
        """One newline per FIFO, and only into one that holds none already."""
        wd = os.path.join(run.rd, "observer.wake.d")
        try:
            names = sorted(os.listdir(wd))
        except OSError:
            return
        for name in names:
            if not name.endswith(".fifo"):
                continue
            path = os.path.join(wd, name)
            try:
                if not stat.S_ISFIFO(os.lstat(path).st_mode):
                    continue
            except OSError:
                continue
            try:
                w = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                # ENXIO: nobody is reading. Skipped this pass, never waited on.
                continue
            try:
                r = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                try:
                    n = struct.unpack("i", fcntl.ioctl(r, termios.FIONREAD, b"\0\0\0\0"))[0]
                finally:
                    os.close(r)
                if n == 0:
                    os.write(w, b"\n")
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EPIPE):
                    log("깨움 실패 %s: %s" % (path, e))
            finally:
                os.close(w)

    # -- precomputed facts -------------------------------------------------

    def input_sig(self, kind, sid, reg, regpath):
        items = [("reg", stat_sig(regpath))]
        idx = reg.get("index") if kind == "pane" else os.path.join(session_dir(), sid)
        items.append(("index", stat_sig(idx)))
        rids = [ln.strip() for ln in (read_text(idx) or "").split("\n") if ln.strip()]
        for rid in rids:
            if "/" in rid or rid in (".", ".."):
                continue
            rd = os.path.join(run_root(), rid)
            items.append((rid, "ledger-path", stat_sig(os.path.join(rd, "ledger-path"))))
            led = (read_text(os.path.join(rd, "ledger-path"), 4096) or "").split("\n", 1)[0]
            if led:
                items.append((rid, "ledger", stat_sig(led)))
                if kind == "pane":
                    items.append((rid, "plan", stat_sig(os.path.join(os.path.dirname(led), rid + ".plan.md"))))
            for name in ("done", "shift.live", "ends-on-done"):
                items.append((rid, name, stat_sig(os.path.join(rd, name))))
            for p in sorted(glob.glob(os.path.join(rd, "*.pid")) + glob.glob(os.path.join(rd, "*.waiting"))):
                items.append((rid, os.path.basename(p), stat_sig(p)))
                if p.endswith(".pid"):
                    items.append((rid, os.path.basename(p), pid_alive(read_int(p))))
                else:
                    items.append((rid, os.path.basename(p), waiting_alive(p)))
            items.append((rid, "shift-alive", pid_alive(read_int(os.path.join(rd, "shift.live")))))
            if kind == "pane":
                items.append((rid, "halt", dir_sig(os.path.join(rd, "halt"))))
        items.append(("borrow", stat_sig(borrow_path(reg))))
        if kind == "pane":
            items.append(("title", stat_sig(os.path.join(state_root(), "session-title-now", sid))))
        return tuple(items)

    def recompute(self, now):
        for kind in ("sl", "pane"):
            kd = obs_path(kind)
            try:
                names = sorted(os.listdir(kd))
            except OSError:
                continue
            for name in names:
                if not name.endswith(".reg"):
                    continue
                sid = name[:-4]
                key = (kind, sid)
                if any(c["key"] == key for c in self.children):
                    continue
                regpath = os.path.join(kd, name)
                reg = read_reg(regpath)
                if reg is None or reg.get("sid") != sid or not sid_ok(sid) \
                        or not script_ok(reg.get("script", ""), KINDS[kind]["script"]) \
                        or (kind == "pane" and not index_ok(reg.get("index", ""))) \
                        or (kind == "sl" and not os.path.isfile(os.path.join(session_dir(), sid))):
                    self.forget(kind, sid)
                    continue
                sig = self.input_sig(kind, sid, reg, regpath)
                st = self.facts.get(key)
                exp = facts_expires(os.path.join(kd, sid + ".facts"))
                if st is not None and st["sig"] == sig:
                    if st.get("retry") is not None:
                        if now < st["retry"]:
                            continue
                    elif exp is not None and now < exp - self.period:
                        continue
                if self.busy() >= CHILD_LIMIT:
                    return
                self.start_facts(kind, sid, reg, sig)

    def forget(self, kind, sid):
        unlink_quiet(obs_path(kind, sid + ".reg"))
        unlink_quiet(obs_path(kind, sid + ".facts"))
        self.facts.pop((kind, sid), None)

    def start_facts(self, kind, sid, reg, sig):
        k = KINDS[kind]
        env = {n[4:]: v for n, v in reg.items() if n.startswith("env.")}
        env["PATH"] = CHILD_PATH
        env[k["var"]] = "1"
        cwd = reg.get("cwd", "/")
        if not os.path.isdir(cwd):
            cwd = "/"
        out = obs_path(kind, ".%s.out.%d" % (sid, self.pid))
        if kind == "sl":
            argv = ["bash", reg["script"]]
            # Unescaped, so the path the status line reads back from this input is
            # the very string the harness hands it; an escaped non-ASCII letter
            # would make the key never match.
            data = (json.dumps({"session_id": sid, "transcript_path": reg.get("transcript", "")},
                               ensure_ascii=False) + "\n").encode("utf-8")
        else:
            argv = ["bash", reg["script"], sid]
            data = b""
        try:
            fo = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                p = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.PIPE, stdout=fo,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
            finally:
                os.close(fo)
        except OSError as e:
            log("사실 계산 기동 실패 %s %s: %s" % (kind, sid, e))
            self.facts[(kind, sid)] = {"sig": sig, "retry": time.time() + FAILED_RETRY_S}
            return
        try:
            p.stdin.write(data)
            p.stdin.close()
        except OSError:
            pass
        self.children.append({"key": (kind, sid), "p": p, "out": out, "sig": sig,
                              "t0": time.monotonic()})

    def reap_children(self):
        keep = []
        for c in self.children:
            p = c["p"]
            if p.poll() is None:
                if time.monotonic() - c["t0"] > CHILD_TIMEOUT_S:
                    kill_group(p)
                    try:
                        p.wait(timeout=2)
                    except subprocess.SubprocessError:
                        keep.append(c)
                        continue
                    self.facts_failed(c, "시한 초과")
                    continue
                keep.append(c)
                continue
            self.facts_done(c)
        self.children = keep

    def facts_failed(self, c, why):
        kind, sid = c["key"]
        unlink_quiet(c["out"])
        log("사실 계산 실패 %s %s: %s" % (kind, sid, why))
        self.facts[c["key"]] = {"sig": c["sig"], "retry": time.time() + FAILED_RETRY_S}

    def facts_done(self, c):
        kind, sid = c["key"]
        text = read_text(c["out"], 1 << 20)
        unlink_quiet(c["out"])
        if text is None or text.split("\n", 1)[0] != KINDS[kind]["head"]:
            self.facts_failed(c, "머리 줄이 맞지 않다")
            return
        if "\ndormant\t1\n" in text or text.endswith("\ndormant\t1"):
            self.forget(kind, sid)
            log("등록 해제(휴면) %s %s" % (kind, sid))
            return
        if not os.path.exists(obs_path(kind, sid + ".reg")):
            return
        try:
            write_atomic(obs_path(kind, sid + ".facts"), text)
        except OSError as e:
            self.facts_failed(c, str(e))
            return
        self.facts[c["key"]] = {"sig": c["sig"], "retry": None}

    def registered(self):
        for kind in ("sl", "pane"):
            try:
                if any(n.endswith(".reg") for n in os.listdir(obs_path(kind))):
                    return True
            except OSError:
                continue
        return False

    # -- the pass ------------------------------------------------------------

    def rotate_log(self):
        try:
            if os.fstat(1).st_size < LOG_CAP:
                return
            lp = obs_path("observer.log")
            os.replace(lp, lp + ".1")
            fd = os.open(lp, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            os.dup2(fd, 1)
            os.dup2(fd, 2)
            os.close(fd)
        except OSError:
            pass

    def superseded(self):
        if time.monotonic() - self.started < SUPERSEDE_AFTER_S:
            return False
        rec = read_record()
        return rec is not None and rec["pid"] != self.pid

    def one_pass(self):
        now = time.time()
        self.rotate_log()
        beat()
        self.take_requests()
        self.apply_drops()
        for run in list(self.runs.values()):
            self.observe(run, now)
        self.batch(now)
        self.apply_drops()
        self.reap_children()
        self.recompute(now)

    def serve(self):
        self.start()
        while not self.stopping:
            t0 = time.monotonic()
            try:
                self.one_pass()
            except Exception as e:  # noqa: BLE001 — one bad pass is logged, not fatal
                log("바퀴 실패: %s" % e)
            if self.superseded():
                log("다른 관측기가 기록을 가졌다")
                break
            if self.runs or self.children or self.registered():
                self.idle_since = time.monotonic()
            elif time.monotonic() - self.idle_since >= self.grace:
                log("유예 종료")
                break
            while not self.stopping and time.monotonic() - t0 < self.period:
                time.sleep(min(0.1, self.period))
        self.shutdown()
        return 0


def stat_sig(path):
    if not path:
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


def dir_sig(path):
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return None
    return tuple((n, stat_sig(os.path.join(path, n))) for n in names)


def relay_sig(path):
    """`relay.live` without its `refreshed=` value, which the waiting loop rewrites
    on every poll."""
    t = read_text(path)
    if t is None:
        return None
    return "\n".join(ln for ln in t.split("\n") if not ln.startswith("refreshed="))


def waiting_alive(path):
    h = ""
    for ln in (read_text(path) or "").split("\n"):
        if ln.startswith("보유자="):
            h = "".join(ln[len("보유자="):].split())
    return h.isdigit() and pid_alive(int(h))


def borrow_path(reg):
    base = reg.get("env.XDG_STATE_HOME") or ""
    if base:
        p = os.path.join(base, "cc-lane", "borrow.json")
    else:
        home = reg.get("env.HOME") or ""
        p = os.path.join(home, ".local", "state", "cc-lane", "borrow.json") if home else ""
    return p if p.startswith("/") else ""


def read_reg(path):
    t = read_text(path)
    if t is None:
        return None
    out = {}
    for ln in t.split("\n"):
        if not ln:
            continue
        k, sep, v = ln.partition("=")
        if not sep:
            return None
        out[k] = v
    return out


def facts_expires(path):
    t = read_text(path, 1 << 20)
    if t is None:
        return None
    for ln in t.split("\n"):
        if ln.startswith("expires\t"):
            v = ln[len("expires\t"):]
            return int(v) if v.isdigit() else None
    return None


def serve():
    d = Daemon()

    def on_signal(signum, frame):
        d.stopping = True
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)
    return d.serve()


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "ensure":
        opts = parse_ensure(rest)
        return ensure(opts if opts is not None else {})
    if cmd == "status":
        return status()
    if cmd == "stop":
        return stop()
    if cmd == "adopt":
        return adopt(rest)
    if cmd == "serve":
        return serve()
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
