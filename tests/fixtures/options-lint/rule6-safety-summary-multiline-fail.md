---
name: fix6ssm
description: t
when_to_use: t
usage: "/cc-cmds:fix [--f]"
options:
  - name: "--f"
    kind: flag
    default: "off"
    summary: "f"
    safety: true
    safety_summary:
      - |
        line A
        line B
      - "bullet 2"
      - "bullet 3"
      - "bullet 4"
---
