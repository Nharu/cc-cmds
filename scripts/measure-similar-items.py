#!/usr/bin/env python3
"""Measure the similar-item lookup against the recorded same-place measurement.

    measure-similar-items.py --data-dir DIR [--question measured|generic]
    measure-similar-items.py --data-dir DIR --live [--patient] [--question measured|generic]

DIR holds the measurement data (`open_issues.json`, `m6_meta.json`,
`m6_log.jsonl`). It is not tracked by git, so pass it as an absolute path.

Without `--live` two legs run, and nothing leaves the machine:

- replay: each of the 20 sampled sources is looked up with its recorded
  judgments replayed (`--replay-log … --replay-tag-prefix B:`). Replay is
  deterministic, so any number other than the pass line is a defect.
- no key: each of the 60 sources with a known answer is looked up against a
  credential store path that does not exist and a closed loopback endpoint.
  Every lookup must fall back to lexical order with `reason=key-absent`.

`--live` sends the 20 sources' judgments for real. That is a paid external
call; the gate grades this harness as an external state change when it is
given.

The lookup is run as a child process by path, never imported, so no bytecode
directory is written beside it.

Exit codes: 0 when every pass condition holds (or the live run completed),
1 when one does not, 2 for a usage error.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL_DIR = os.path.join(HERE, "..", "plugins", "cc-cmds", "orchestrator")
TOOL = os.path.join(TOOL_DIR, "similar-items.py")
CHILD_TIMEOUT = 1200


def closed_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_tool(argv, env):
    child_env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    child_env.update(env)
    try:
        cp = subprocess.run([TOOL] + argv, env=child_env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=CHILD_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "spawn failed (%s)" % type(e).__name__
    if cp.returncode != 0:
        return None, "rc=%d %s" % (cp.returncode, cp.stderr.decode("utf-8", "replace").strip()[:200])
    try:
        return json.loads(cp.stdout.decode("utf-8")), None
    except ValueError:
        return None, "unparseable output"


def key_of(d, n):
    return d[str(n)] if str(n) in d else d[n]


def score(res, gold):
    """(best rank after re-rank, best lexical rank) of a known answer, or None."""
    cands = res["candidates"]
    final = [c["id"] for c in cands]
    lexical = [c["id"] for c in sorted(cands, key=lambda c: c["lexical"])]
    hit = [g for g in gold if g in final]
    if not hit:
        return None
    return min(final.index(g) + 1 for g in hit), min(lexical.index(g) + 1 for g in hit)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="measure-similar-items.py", allow_abbrev=False,
                                 description="Measure the similar-item lookup against the recorded measurement.")
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--patient", action="store_true")
    ap.add_argument("--question", choices=("measured", "generic"))
    args = ap.parse_args(argv)
    if args.patient and not args.live:
        ap.error("--patient is only meaningful with --live")
    data = os.path.abspath(args.data_dir)
    corpus = os.path.join(data, "open_issues.json")
    try:
        with open(os.path.join(data, "m6_meta.json"), encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, ValueError) as e:
        ap.error("cannot read m6_meta.json under --data-dir (%s)" % type(e).__name__)
    srcs = [int(s) for s in meta["srcs"]]
    qarg = ["--question", args.question] if args.question else []
    errors = []

    if args.live:
        semantic = den = top3 = top1 = 0
        mismatch = 0
        for s in srcs:
            res, err = run_tool(["file", "--corpus", corpus, "--issue", str(s), "--format", "json"]
                                + (["--patient"] if args.patient else []) + qarg, {})
            if err:
                errors.append("%s: %s" % (s, err))
                continue
            semantic += res["status"] == "semantic"
            mismatch += "model-mismatch" in res["reason"].split(",")
            r = score(res, set(int(g) for g in key_of(meta["gold"], s)))
            if r:
                den += 1
                top3 += r[0] <= 3
                top1 += r[0] == 1
        print("measure-similar-items: live top3=%d/%d top1=%d/%d semantic=%d/%d model=%s errors=%d" % (
            top3, den, top1, den, semantic, len(srcs), "mismatch" if mismatch else "jev-1.13.0", len(errors)))
        for e in errors:
            print("error: " + e, file=sys.stderr)
        return 1 if errors else 0

    # The no-key leg points the credential store at a path that must not exist.
    # It is checked, never created: this harness writes nothing.
    store = os.path.join(data, ".no-key-store")
    if os.path.lexists(store):
        ap.error("%s exists; the no-key leg needs a credential store path that does not exist" % store)

    log = os.path.join(data, "m6_log.jsonl")
    semantic = den = top3 = top1 = lex3 = lex1 = hits = pairs = same_list = 0
    for s in srcs:
        res, err = run_tool(["file", "--corpus", corpus, "--issue", str(s), "--replay-log", log,
                             "--replay-tag-prefix", "B:", "--format", "json"] + qarg, {})
        if err:
            errors.append("replay %s: %s" % (s, err))
            continue
        semantic += res["status"] == "semantic"
        hits += res["judged"]
        pairs += res["shortlist"]
        lexical = [c["id"] for c in sorted(res["candidates"], key=lambda c: c["lexical"])]
        same_list += lexical == [int(v) for v in key_of(meta["shortlist"], s)]
        r = score(res, set(int(g) for g in key_of(meta["gold"], s)))
        if r:
            den += 1
            top3 += r[0] <= 3
            top1 += r[0] == 1
            lex3 += r[1] <= 3
            lex1 += r[1] == 1

    nokey_env = {"CC_CMDS_CRED_STORE": store, "CC_SIMILAR_JEV_URL": "http://127.0.0.1:%d" % closed_port()}
    gold_srcs = sorted(int(s) for s in meta["gold"])
    nokey = 0
    for s in gold_srcs:
        res, err = run_tool(["file", "--corpus", corpus, "--issue", str(s), "--format", "json"] + qarg, nokey_env)
        if err:
            errors.append("no-key %s: %s" % (s, err))
            continue
        nokey += (res["status"] == "lexical" and res["reason"] == "key-absent"
                  and bool(res["notice"]) and len(res["candidates"]) >= 1)

    pycache = os.path.exists(os.path.join(TOOL_DIR, "__pycache__"))
    print("measure-similar-items: replay top3=%d/%d top1=%d/%d hash=%d/%d shortlist=%d/%d semantic=%d/%d"
          " lexical-only top3=%d/%d top1=%d/%d no-key=%d/%d pycache=%s" % (
              top3, den, top1, den, hits, pairs, same_list, len(srcs), semantic, len(srcs),
              lex3, den, lex1, den, nokey, len(gold_srcs), "present" if pycache else "absent"))
    for e in errors:
        print("error: " + e, file=sys.stderr)
    ok = (not errors and den == 17 and top3 == 13 and top1 == 9 and hits == 400 and pairs == 400
          and same_list == len(srcs) == 20 and semantic == 20 and lex3 == 13 and lex1 == 7
          and nokey == len(gold_srcs) == 60 and not pycache)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
