# Korean UX Templates (fixture — base)

### §3.9.4.f — Reused 3-option prompt: per-trigger reason variants (all four EXIT_TRIGGER values)

- `inner-limit`: downstream early-termination clause `내부 라운드가 안전 한계로 조기 종료됨`.
- `async-slow`: downstream early-termination clause `비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨`.
- `lostwrite`: downstream early-termination clause `라운드 결과 파일이 반복 유실되어 조기 종료됨`.
- trigger-neutral fallback: downstream early-termination clause `내부 라운드가 조기 종료됨`, summary clause `이터레이션 조기 종료 시점에 미해소`.
