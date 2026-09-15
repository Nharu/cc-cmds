# 설계 브리프 — docs-x
<!-- cc-design-brief v1; writer=design; reader=design-discuss-unattended; owner-doc=docs/x.md; NOT a design doc; mechanism-local, never staged by a skill -->

## 요구사항
- 로그인 실패 시 재시도 횟수를 서버가 제한한다.
- 기존 세션 쿠키 형식은 바꾸지 않는다.

## 제약
- `src/auth/` 밖의 파일은 건드리지 않는다.

## 배포 형상
**레포**: example/app
**슬라이스 수**: 1
**적용 위치**: 없음
**적용 주체**: 없음
**실패 시 파킹**: 없음

## 탐색 결과
- `src/auth/limiter.ts` 에 이미 토큰 버킷이 있다.

## 재현
없음

## 팀 구성
- domain (opus): 인증 흐름과 제한기 설계
- verification (sonnet): 제한기 동작 실측

## 기준선
```text
 M src/auth/limiter.ts
```

## 대상
**topic-slug**: x
**문서 키**: docs/x.md
**접힌 슬러그**: docs-x
**docs 대상 디렉터리**: docs/
**검증 편중 프로필**: 아니오

<!-- cc-design-brief: end -->
