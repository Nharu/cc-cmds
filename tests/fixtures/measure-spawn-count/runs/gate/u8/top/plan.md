# 파이프라인 런 매니페스트 — R1
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=R1;
     anchor-kind=repo; anchor-key=t/front;
     owner-doc=(없음); origin-worktree=@ROOT@/u8/wt;
     NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: 2026-01-01T00:00:00Z
**런 id**: R1
**앵커 종류**: repo
**앵커 키**: t/front
**사용자 확인 문면**: 측정 픽스처

## 의도
```text
측정
```

## 대상
**대상 맵 다이제스트**: @TD@
- `target` | 별칭=front | 메인 워크트리=@ROOT@/u8/wt | 공통 git 디렉터리=@ROOT@/u8/wt/.git | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/front | 절단점=PR | 말단 행위 상한=없음

## 요소
**설계 문서**: (없음)
**적용 주체**: (해당 없음)

## 실행 계획
**계획 다이제스트**: @PD@
**승인 문면**: 측정
```json
{ "steps": [] }
```

## 인가
**런 최대 절단점**: PR
**종료 지점**: 픽스처가 끝나면
**벽시계 마감**: 2030-01-01T00:00:00Z
**시각 정합 마커**: 없음
**사다리 가용 단 수**: 4
**미선언 상황 처분**: park
