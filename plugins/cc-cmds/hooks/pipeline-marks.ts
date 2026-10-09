// 파이프라인 표지 판정. `$` 를 받지 않는 순수 함수만 둔다 — 표지 변수는
// 부르는 쪽이 같은 파일에서 리터럴 이름으로 읽어 값만 넘긴다.

// 값이 참인 표지가 하나라도 있으면 참. 정의돼 있어도 빈 문자열이면 표지가 아니다.
export function anyMarked(values: readonly (string | undefined | null)[]): boolean {
  return values.some(v => typeof v === 'string' && v !== '')
}
