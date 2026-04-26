---
name: beta
description: beta command with safety
when_to_use: when behavior auto-changes are involved
usage: "/cc-cmds:beta <doc> [--no-auto]"
options:
    - name: "<doc>"
      kind: positional
      required: true
      summary: "대상 문서 경로"
    - name: "--auto"
      kind: flag
      noop: true
      default: "(no-op alias — auto는 기본 ON)"
      summary: "명시적 opt-in 별칭"
    - name: "--no-auto"
      kind: flag
      default: "off (즉, auto 활성)"
      safety: true
      summary: "Auto 모드를 세션 전체에서 비활성화"
      safety_summary:
          - "**기본 동작** — auto는 ON. 도미넌트 옵션을 자동 선택."
          - "**Blackout** — 파괴적 작업은 항상 사용자에게 escalate."
          - "**Revert** — 자동 결정은 참조 ID로 되돌릴 수 있음."
          - "**Opt-out** — `--no-auto` 지정 시 전체 세션에서 비활성화."
---

Body kept minimal for fixture.
