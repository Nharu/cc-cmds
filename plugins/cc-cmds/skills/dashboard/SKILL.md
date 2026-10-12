---
name: dashboard
description: 이 호스트의 autopilot 런들을 한 화면에 보여주는 로컬 대시보드 서버를 띄우고 링크를 알려준다
when_to_use: 사용자가 런 진행 대시보드를 다시 열거나, 서버가 꺼졌다는 안내(「서버가 꺼져 있습니다 — `/cc-cmds:dashboard`」)를 보고 다시 올리려 할 때
disable-model-invocation: true
usage: "/cc-cmds:dashboard [<run-id>]"
options:
    - name: "<run-id>"
      kind: positional
      required: false
      summary: "링크가 바로 가리킬 런 id. 없으면 전체 런 목록 링크를 낸다."
      parse_note: "인자 전체를 런 id 하나로 쓴다. 비어 있으면 목록 링크다."
---

Bring up the local run dashboard and show the person its link. This is a single command, not a workflow: one call, one line of output, done.

## Steps

1. **Resolve the plugin root** the same way the other skills do:

    ```bash
    PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "${CLAUDE_SKILL_DIR}/../.." && pwd)}"
    ```

2. **Check for `python3`.** The dashboard is Python 3.9 standard library only. If `command -v python3` finds nothing, tell the person 「대시보드 없음 — python3 를 찾지 못했습니다」 and stop.

3. **Run the command.** Pass the run id only when the argument is non-empty:

    ```bash
    python3 "$PLUGIN_DIR/orchestrator/dashboard.py" open [<run-id>]
    ```

    `open` starts the server when none of this plugin's servers answers (or replaces one of another version), then prints the link. It never fails the caller: a server that could not be started still yields a link line, ending in 「서버가 꺼져 있습니다 — `/cc-cmds:dashboard`」.

4. **Show the printed line to the person verbatim**, in Korean framing. Do not open a browser, do not fetch the link, and do not summarize the line away — the link is the whole output.

Nothing here writes to a repository, a ledger or a run directory. `dashboard.py status` and `dashboard.py stop` exist for a person at a shell and are not part of this skill.
