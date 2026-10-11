#!/usr/bin/env python3
"""Hang one ClickUp task on another.

    clickup-relate.py --task T --depends-on P

Sends one `POST /task/{T}/dependency` carrying `depends_on: P`, so task T is
waiting on task P, and prints `<T>\t<P>`. Nothing else about either task is
touched.

Inside an unattended pipeline run (`CC_PIPELINE_MANIFEST` set) a relation is
written only when the manifest's `## 인가` carries exactly one row
`` - `베이스 발행` | 트래커=clickup | 대상=<list id> ``. The row is frozen at
kickoff, while a person is present; any other run writes nothing.

Exit codes: 0 related, 2 usage error, 3 no usable token, 4 API error,
5 refused inside an unattended pipeline run (no frozen ClickUp publish row),
1 internal error.

Run it by path, with no interpreter in front: the gate grades the basename,
and an interpreter prefix is graded as an opaque worktree write.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import socket  # noqa: E402
import urllib.error  # noqa: E402
import urllib.parse  # noqa: E402
import urllib.request  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import cc_tracker  # noqa: E402

ATTEMPT_TIMEOUT = 15.0
PUBLISH_ROW_PREFIX = "- `베이스 발행` | "


class ApiError(Exception):
    """The request did not produce the relation. The message never carries
    the token."""


def build_parser():
    # Abbreviations are refused, as on the create tool: the gate reads the
    # option spellings it can see.
    parser = argparse.ArgumentParser(prog="clickup-relate.py", allow_abbrev=False,
                                     description="Make one ClickUp task depend on another.")
    parser.add_argument("--task", required=True, help="the task that waits")
    parser.add_argument("--depends-on", required=True, help="the task it waits on")
    return parser


def frozen_publish_tracker(manifest_path):
    """The tracker of the one `베이스 발행` row inside the manifest's
    `## 인가`, or None when there is none, several, or the file cannot be
    read."""
    try:
        with open(manifest_path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return None
    rows, inside = [], False
    for line in lines:
        if line.startswith("## "):
            inside = line == "## 인가"
            continue
        if inside and line.startswith(PUBLISH_ROW_PREFIX):
            rows.append(line)
    if len(rows) != 1:
        return None
    for part in rows[0][len(PUBLISH_ROW_PREFIX):].split(" | "):
        key, sep, value = part.partition("=")
        if sep and key.strip() == "트래커":
            return value.strip() or None
    return None


def send(url, token, body):
    """POST once, and once more only when no response came back at all.

    An HTTP error, a timeout or an unreadable response may mean the relation
    was written, so none of them is retried.
    """
    opener = cc_tracker.opener_for(url)
    for attempt in range(2):
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": token, "Content-Type": "application/json"})
        try:
            with opener.open(req, timeout=ATTEMPT_TIMEOUT) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise ApiError("HTTP %s" % e.code)
        except socket.timeout:
            raise ApiError("timeout")
        except (urllib.error.URLError, ConnectionError) as e:
            if isinstance(getattr(e, "reason", None), socket.timeout):
                raise ApiError("timeout")
            if attempt == 0:
                continue
            raise ApiError("connection failed")
        except (OSError, http.client.HTTPException):
            raise ApiError("connection failed")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            raise ApiError("response is not JSON")
        if not isinstance(data, dict) or data.get("err"):
            raise ApiError("response reports an error")
        return data
    raise ApiError("connection failed")


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return relate(args)
    except Exception as e:  # never echo a value that might carry the token
        sys.stderr.write("clickup-relate.py: internal error (%s)\n" % type(e).__name__)
        return 1


def relate(args):
    manifest = os.environ.get("CC_PIPELINE_MANIFEST")
    if manifest and frozen_publish_tracker(manifest) != "clickup":
        sys.stderr.write("clickup-relate.py: refused inside an unattended pipeline run "
                         "(no frozen ClickUp publish row)\n")
        return 5
    try:
        base = cc_tracker.clickup_base()
    except cc_tracker.UsageError as e:
        sys.stderr.write("clickup-relate.py: %s\n" % e)
        return 2
    token, why = cc_tracker.read_clickup_token()
    if token is None:
        if why == "tracker-key-invalid":
            sys.stderr.write("clickup-relate.py: ~/.config/cc-cmds/clickup.env must be a regular file "
                             "with mode 600\n")
        else:
            sys.stderr.write("clickup-relate.py: no ClickUp token in ~/.config/cc-cmds/clickup.env\n")
        return 3
    url = base + "/task/%s/dependency" % urllib.parse.quote(args.task, safe="")
    body = json.dumps({"depends_on": args.depends_on}).encode()
    try:
        send(url, token, body)
    except ApiError as e:
        sys.stderr.write("clickup-relate.py: relation not written (%s)\n" % e)
        return 4
    finally:
        del token
    line = "%s\t%s\n" % (args.task, args.depends_on)
    sys.stdout.buffer.write(line.encode("utf-8"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
