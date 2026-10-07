// 런 상태 패널 mod(hooks/autopilot-status.tsx)가 $.state 에 두는 값의 계약.

/** 헬퍼 본문 한 줄: 색조와 문구. 색조는 헬퍼가 정하고 mod 는 그리기만 한다. */
export type PaneLine = { tone: string; text: string }

/** 패널이 그리는 것: 마지막으로 성공한 헬퍼 실행의 본문과, 그 뒤 실패를 알리는 경고 줄. */
export type PaneSnapshot = { lines: PaneLine[]; warning: string | null }

/** 자동 열기·닫힘 기록과 갱신 주기 판단에 쓰는 값. 모듈이 다시 적재되어도 남아야 한다. */
export type PaneControl = {
  /** 묻지 않고 패널을 연 런 id. 런마다 한 번만 연다. */
  autoOpenedFor: string[]
  /** 사람이 패널을 닫은 런 id. 이 런으로는 다시 저절로 열지 않는다. */
  dismissedFor: string[]
  /** 마지막 헬퍼 실행 시각(ms). 실행한 적 없으면 null. */
  lastRunAt: number | null
  /** 마지막으로 본 세션 목록 mtime. 목록이 없으면 null. */
  lastMtime: number | null
  /** 마지막 헬퍼 실행에 넘긴 세션 id. */
  lastSid: string | null
  /** 마지막 좋은 머리 행의 런 id. 런이 없으면 null. */
  rid: string | null
  /** 마지막 좋은 머리 행의 세션 목록 절대 경로. 없으면 null. */
  indexPath: string | null
  /** 마지막 좋은 머리 행의 갱신 주기(ms). */
  refreshMs: number
}

declare module 'claude-code' {
  interface PluginState {
    'cc-cmds': { paneSnapshot: PaneSnapshot; paneControl: PaneControl }
  }
}
