---
name: design-upgrade
description: 팀원 모델 업그레이드 분석
when_to_use: design 스킬의 팀 구성 제안에서 haiku/sonnet으로 배정된 팀원 중 opus로 승격이 유의미한 역할이 있는지 검토할 때
disable-model-invocation: true
usage: "/cc-cmds:design-upgrade"
options: []
notes: |
    이 커맨드는 별도 인자를 받지 않으며, 직전 `/design` 팀 제안이 현재 대화 컨텍스트에 있어야 동작한다. 독립 실행 시 결과가 불정확할 수 있다.
---

haiku, sonnet으로 제안된 팀원 중 opus로 변경하면 이점이 있는 팀원이 있는지 분석해줘.

## 판단 기준

복잡한 추론, 크로스 도메인 분석, 깊은 코드 분석 등 opus의 강점이 유의미한 차이를 만들 수 있는 역할을 중심으로 판단하되, 해당 설계의 특성에 따라 다른 관점도 고려할 것.

## 출력 형식

팀원별로 다음을 제시:
- 현재 모델 → 권장 모델
- 변경 사유 (또는 유지 사유)
- 기대 효과
