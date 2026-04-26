---
name: alpha
description: alpha command with variants
when_to_use: when input shape varies
usage: "/cc-cmds:alpha [<target>]"
options:
    - name: "<target>"
      kind: positional
      required: false
      summary: "리뷰 대상. 입력 형태에 따라 자동 분기."
      parse_note: "숫자만 포함된 토큰은 PR 번호로 해석."
      variants:
          - label: "PR 번호"
            example: "42"
            behavior: "숫자만일 때 PR 번호로 해석"
          - label: "파일 경로"
            example: "src/auth/"
            behavior: "파일 리뷰 모드"
          - label: "(생략)"
            behavior: "현재 브랜치 자동 감지"
---

Body kept minimal for fixture.
