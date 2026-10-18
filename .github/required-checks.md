# 필수 체크 이름 (브랜치 보호용)

`master` 에 브랜치 보호를 걸 때 required status check 로 지정할 이름의 전수다. **손으로 적은 것이 아니라 아래 이름이 모두 체크 런으로 생겨 끝난 실행에서 채취했다** (실패한 체크가 있으면 채취한 실행 줄에 적는다) — 이름은 워크플로 파일의 잡 키가 아니라 GitHub 이 렌더한 체크 이름이고, matrix 잡은 `<잡 이름> (<값>)` 으로 갈라지므로 파일만 보고 적으면 어긋난다.

- **채취한 실행**: `Nharu/cc-cmds#1338`, head `4810ac3dd531a68da7ac238e48a80003fb94686b`
  (워크플로 실행 `39145561992` gate · `39145561977` lint · `39145561979` notify-macos, 2026-10-18, 20개 중 19개 success)
  - 실패: `gate-shards (2)` — base `master` `df3ea9506bb9f9cd3ef51538a35253a10ebc1590` 의 gate 실행 `39137106110` 에서도 같은 이름의 잡이 같은 `FAIL: 59: 그 셋의 예산이 전부 gate_free_budget 에서 온다 — got '4', want '3'` 줄로 실패했다

## 게이트 소속 (13) — `.github/workflows/gate.yml` 의 샤드 matrix

```
gate-shards (1)
gate-shards (2)
gate-shards (3)
gate-shards (4)
gate-shards (5)
gate-shards (6)
gate-shards (7)
gate-shards (8)
gate-shards (9)
gate-shards (10)
gate-shards (11)
gate-shards (12)
gate-shards (13)
```

샤드 수는 `Makefile` 의 `GATE_SHARDS` 하나가 정한다. 그 값을 바꾸면 이 목록도 함께 바뀌므로, matrix·`--check`·이 파일 셋을 같은 커밋에서 맞춘다.

## 나머지 (7)

```
shard-coverage      .github/workflows/gate.yml
census-ratchet      .github/workflows/gate.yml
lint-and-readme     .github/workflows/lint.yml
rest-tests (1)      .github/workflows/lint.yml
rest-tests (2)      .github/workflows/lint.yml
rest-tests (3)      .github/workflows/lint.yml
lint-and-test-macos .github/workflows/notify-macos.yml
```

`rest-tests` 의 샤드 수는 `Makefile` 의 `REST_SHARDS` 가 정한다. 바꿀 때는 `.github/workflows/lint.yml` 의 matrix 와 이 목록을 같은 커밋에서 맞춘다.

## 이 목록을 그대로 required 로 걸기 전에 읽을 것

**세 워크플로 전부 `pull_request` 에 경로 필터를 달고 있어 「항상 도는」 잡은 하나도 없다.** GitHub 은 경로 필터로 건너뛴 워크플로에 체크 런을 만들지 않고, required 로 지정된 체크가 없으면 그 PR 을 무기한 대기로 둔다. 따라서 위 20개를 그대로 required 로 걸면 **그 경로를 건드리지 않는 PR 은 영원히 머지할 수 없다.**

거는 쪽이 고를 수 있는 것은 둘이다.

1. 경로 필터와 required 집합을 맞춘다 — 각 워크플로에 필터가 걸러낸 경우 즉시 성공하는 동명의 대체 잡을 두거나, 필터를 걷어낸다.
2. required 를 걸지 않고 이 목록을 관측용으로만 쓴다.

어느 쪽도 이 파일이 정하지 않는다. 이 파일이 보장하는 것은 **이름이 실물과 같다**는 것 하나다.
