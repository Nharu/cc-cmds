# 필수 체크 이름 (브랜치 보호용)

`master` 에 브랜치 보호를 걸 때 required status check 로 지정할 이름의 전수다. **손으로 적은 것이 아니라 아래 이름이 모두 체크 런으로 생겨 끝난 실행에서 채취했다** (실패한 체크가 있으면 채취한 실행 줄에 적는다) — 이름은 워크플로 파일의 잡 키가 아니라 GitHub 이 렌더한 체크 이름이고, matrix 잡은 `<잡 이름> (<값>)` 으로 갈라지므로 파일만 보고 적으면 어긋난다.

- **채취한 실행**: `Nharu/cc-cmds#1499`, head `d0b172230c46cdfbff154521ff9391b3d7891a38`
  (워크플로 실행 `40448029690` gate · `40448029582` lint · `40448029603` notify-macos, 2026-10-27, 37개 중 34개 success — `gate-isolation`·`rest-tests (1)`·`rest-tests (3)` 은 failure. 그 실행에는 추가 행 `gate-shards (27)` 도 있었고, 아래 까닭으로 목록과 수에 넣지 않는다)
- `gate-isolation` 은 잡에 `name:` 이 없어 체크 이름이 잡 키 그대로다. 위 실행에서 체크 런으로 생긴 것을 확인했다.

**추가 행 이름은 이 목록에 없다.** gate 의 matrix 는 고정 목록이 아니라 `gate-plan` 이 낸 행 목록이다. 정규 러너 1..26 뒤에, 바뀐 절의 격리 작업이 정규 행의 여유를 넘친 PR 에서만 추가 행 `gate-shards (27)` 이상(최대 `Makefile` 의 `GATE_ISO_EXTRA` 개)이 붙는다. 바뀐 절이 없거나 여유에 다 실린 PR 에는 그 체크 런이 생기지 않으므로, required 로 걸면 그런 PR 이 무기한 대기한다. 추가 행의 실패는 그 행의 체크와 `gate-isolation` 에 드러난다.

## 게이트 소속 (26) — `.github/workflows/gate.yml` 의 샤드 matrix

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
gate-shards (14)
gate-shards (15)
gate-shards (16)
gate-shards (17)
gate-shards (18)
gate-shards (19)
gate-shards (20)
gate-shards (21)
gate-shards (22)
gate-shards (23)
gate-shards (24)
gate-shards (25)
gate-shards (26)
```

샤드 수는 `Makefile` 의 `GATE_SHARDS` 하나가 정한다. matrix 는 `gate-plan` 이 그 값으로 만들고 `shard-coverage` 가 표와 대조하므로, 그 값을 바꾸면 이 목록만 같은 커밋에서 맞춘다.

## 나머지 (11)

```
gate-plan           .github/workflows/gate.yml
shard-coverage      .github/workflows/gate.yml
census-ratchet      .github/workflows/gate.yml
gate-report         .github/workflows/gate.yml
gate-isolation      .github/workflows/gate.yml
lint-and-readme     .github/workflows/lint.yml
rest-tests (1)      .github/workflows/lint.yml
rest-tests (2)      .github/workflows/lint.yml
rest-tests (3)      .github/workflows/lint.yml
rest-duration       .github/workflows/lint.yml
lint-and-test-macos .github/workflows/notify-macos.yml
```

`rest-tests` 의 샤드 수는 `Makefile` 의 `REST_SHARDS` 가 정한다. 바꿀 때는 `.github/workflows/lint.yml` 의 matrix 와 이 목록을 같은 커밋에서 맞춘다.

## 이 목록을 그대로 required 로 걸기 전에 읽을 것

**세 워크플로 전부 `pull_request` 에 경로 필터를 달고 있어 「항상 도는」 잡은 하나도 없다.** GitHub 은 경로 필터로 건너뛴 워크플로에 체크 런을 만들지 않고, required 로 지정된 체크가 없으면 그 PR 을 무기한 대기로 둔다. 따라서 위 37개를 그대로 required 로 걸면 **그 경로를 건드리지 않는 PR 은 영원히 머지할 수 없다.**

거는 쪽이 고를 수 있는 것은 둘이다.

1. 경로 필터와 required 집합을 맞춘다 — 각 워크플로에 필터가 걸러낸 경우 즉시 성공하는 동명의 대체 잡을 두거나, 필터를 걷어낸다.
2. required 를 걸지 않고 이 목록을 관측용으로만 쓴다.

어느 쪽도 이 파일이 정하지 않는다. 이 파일이 보장하는 것은 **이름이 실물과 같다**는 것 하나다.
