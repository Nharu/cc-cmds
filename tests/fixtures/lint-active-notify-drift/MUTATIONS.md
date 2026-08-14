# Mutation list for `lint-active-notify-drift.sh`

The rows live in `tests/fixtures/lint-active-notify-drift-mutations/`, one
directory per mutation, and `scripts/test-lint-active-notify-drift-mutations.sh`
runs them. **The harness is the artifact, not the list** — a list of strings
with no runner transfers its verdict to whatever machinery the next reader
builds, and the failure that produced this file was a harness reading the wrong
stream and reporting "nothing pins this" with total confidence.

This is documentation beside a runnable harness. It is **not** a gate, it is not
wired into `make lint` or `make test`, and it does not cover the class of defect
where a statement is false from the moment it is written.

## 조항·읽기 규칙 — 정본은 여기가 아니다

행이 갖춰야 할 네 조항, 문법 검사의 양상, 깨끗한 실행이 licence하는 것과 하지 않는
것, 그리고 잡히지 않는 양쪽 퇴화 끝의 공시는 **`tests/mutation-harness/README.md`**
가 갖는다. 이 파일은 그것을 **인용**하고 다시 쓰지 않는다 — 조항을 코퍼스마다 다시
쓰는 것이 이 하네스 계열이 이미 한 번 겪은 발산의 형태다.

이 파일이 갖는 것은 **이 코퍼스 고유의 것**뿐이다: 아래 공시와 측정, 그리고 행 목록
(`tests/fixtures/lint-active-notify-drift-mutations/`).

## 이 코퍼스의 공시

첫 실행에서 일곱 행이 빈 적색 집합으로 돌아왔다. 대응은 벡터 일곱 개를 고치는 것이
아니라 픽스처 넷을 새로 만들고 둘을 다시 쓰는 것이었다 — 벡터를 관측에서 쓰면 언제나
맞아떨어지고 무엇이든 승인한다. 다시 쓴 둘은 광고한 것과 다른 이유로 통과하고 있었다:

- 한 픽스처는 근접 부정어로 `fire-now`를 썼는데 그것은 **후행** 경계가 이미 막고 있어
  (뒤에 `w`가 온다) 자기가 겨냥한 **선행** 경계에 대해 아무 말도 하지 않았다.
- 다른 하나는 다섯 형태를 경계 없는 한 줄기에 늘어놓아 추출기가 하나로 합치는 바람에
  넷이 시험되지 않았다.

## Re-deriving the figures

Run the harness. Do not carry numbers forward from here or from a commit
message — the fixture set moves, and a figure copied across a fixture addition
is stale on arrival.

```
bash scripts/test-lint-active-notify-drift-mutations.sh --self-check
```

`--self-check` additionally runs one row against a deliberately wrong vector and
requires the harness to reject it. A harness that has never rejected anything is
indistinguishable from one that cannot.
