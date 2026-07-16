# Korean UX Templates (fixture — base)

### §3.9.4.f — Reused 3-option prompt: per-trigger reason variants (all four EXIT_TRIGGER values)

- `inner-limit`: downstream early-termination clause `내부 라운드가 안전 한계로 조기 종료됨`, summary clause `내부 안전 한계 도달 시점에 미해소`.
- `async-slow`: reason line `비동기 리뷰어가 아직 완료 witness를 발행하지 못했습니다.`, downstream early-termination clause `비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨`, summary clause `비동기 리뷰어 미완료로 미해소`.
- `lostwrite`: reason line `라운드 결과 파일이 완료 표시 후에도 반복 유실되었습니다 — 같은 라운드 재시도 {K65}회로도 복구되지 않았습니다.`, downstream early-termination clause `라운드 결과 파일이 반복 유실되어 조기 종료됨`, summary clause `라운드 결과 파일 반복 유실로 미해소`.
- trigger-neutral fallback: downstream early-termination clause `내부 라운드가 조기 종료됨`, summary clause `이터레이션 조기 종료 시점에 미해소`.
