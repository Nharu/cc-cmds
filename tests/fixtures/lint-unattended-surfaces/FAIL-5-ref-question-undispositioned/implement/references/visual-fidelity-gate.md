# Visual fidelity gate (fixture)

- **Tier C — graceful degrade**: 둘 다 없으면 조용히 통과하지 않고
  `AskUserQuestion` 으로 라우팅한다(fail-open: 레시피 제공 / 이 화면 skip /
  게이트 비활성). 조용한 self-disable 금지.

A backticked bare name with no parenthesis, which is what the call-form pattern
walks past.
