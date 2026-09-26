#!/usr/bin/env python3
"""Create one ClickUp ticket in a list.

    clickup-create.py --list ID --name T --description-file F

Sends one `POST /list/{list_id}/task` carrying the name and the file's text as
the Markdown description, and prints `<id>\t<url>` of the new ticket. No
assignee, status, priority, due date or tag is sent: those are decided when
work on the ticket starts, not when it is filed.

The similar-ticket lookup does not run here. It is `similar-items.py`, which
holds no tracker write, so a write never hides behind the lookup's name.

Exit codes: 0 created, 2 usage error, 3 no usable token, 4 API error,
5 refused inside an unattended pipeline run (an unattended run files no
ticket), 1 internal error.

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


class ApiError(Exception):
    """The create request did not produce a ticket. The message never carries
    the token or the description."""


def build_parser():
    # Abbreviations are refused, as on the lookup tool: the gate reads the
    # option spellings it can see.
    parser = argparse.ArgumentParser(prog="clickup-create.py", allow_abbrev=False,
                                     description="Create one ClickUp ticket in a list.")
    parser.add_argument("--list", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--description-file", required=True)
    return parser


def send(url, token, body):
    """POST once, and once more only when no response came back at all.

    A POST is not idempotent: an HTTP error, a timeout or an unreadable
    response may mean the ticket was made, so none of them is retried.
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
            data = json.loads(raw)
        except ValueError:
            raise ApiError("response is not JSON")
        if not isinstance(data, dict) or data.get("id") is None:
            raise ApiError("response carries no ticket id")
        return data
    raise ApiError("connection failed")


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return create(args)
    except Exception as e:  # never echo a value that might carry the token
        sys.stderr.write("clickup-create.py: internal error (%s)\n" % type(e).__name__)
        return 1


def create(args):
    if os.environ.get("CC_PIPELINE_MANIFEST"):
        sys.stderr.write("clickup-create.py: refused inside an unattended pipeline run\n")
        return 5
    try:
        base = cc_tracker.clickup_base()
    except cc_tracker.UsageError as e:
        sys.stderr.write("clickup-create.py: %s\n" % e)
        return 2
    try:
        with open(args.description_file, encoding="utf-8") as f:
            description = f.read()
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write("clickup-create.py: cannot read %s (%s)\n" % (args.description_file, type(e).__name__))
        return 2
    token, why = cc_tracker.read_clickup_token()
    if token is None:
        if why == "tracker-key-invalid":
            sys.stderr.write("clickup-create.py: ~/.config/cc-cmds/clickup.env must be a regular file "
                             "with mode 600\n")
        else:
            sys.stderr.write("clickup-create.py: no ClickUp token in ~/.config/cc-cmds/clickup.env\n")
        return 3
    url = base + "/list/%s/task" % urllib.parse.quote(args.list, safe="")
    body = json.dumps({"name": args.name, "markdown_description": description}).encode()
    try:
        data = send(url, token, body)
    except ApiError as e:
        sys.stderr.write("clickup-create.py: ticket not created (%s)\n" % e)
        return 4
    finally:
        del token
    line = "%s\t%s\n" % (data.get("id"), data.get("url") or "")
    sys.stdout.buffer.write(line.encode("utf-8"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
