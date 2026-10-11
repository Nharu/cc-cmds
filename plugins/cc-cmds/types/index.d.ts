// 런 상태 패널 mod(hooks/autopilot-status.tsx)와 질문지 서브 mod(hooks/question-form/)가
// $.state 에 두는 값의 계약.

/** 한 줄 안의 색조 조각. 색조는 헬퍼가 정하고 mod 는 그리기만 한다. */
export type PanePart = { tone: string; bold: boolean; text: string }

/**
 * 헬퍼 본문 한 줄: 묶음 id, 감을지(`wrap`) 끝을 자를지(`cut`), 그리고 조각들.
 * 줄 하나는 한 번 감기거나 한 번 잘린다.
 */
export type PaneLine = { bundle: string; wrap: boolean; parts: PanePart[] }

/** 패널이 그리는 것: 마지막으로 성공한 헬퍼 실행의 본문과, 그 뒤 실패를 알리는 경고 줄. */
export type PaneLines = { lines: PaneLine[]; warning: string | null }

/** 자동 열기·닫힘 기록과 갱신 주기 판단에 쓰는 값. 모듈이 다시 적재되어도 남아야 한다. */
export type PaneControl = {
  /** 묻지 않고 패널을 연 런 id. 런마다 한 번만 연다. */
  autoOpenedFor: string[]
  /** 사람이 패널을 닫은 런 id. 이 런으로는 다시 저절로 열지 않는다. */
  dismissedFor: string[]
  /** 마지막 헬퍼 실행을 시작하기 전에 읽은 시각(ms). 실행한 적 없으면 null. */
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

/** 질문지 선택지. 추천 표시는 라벨이 아니라 recommended 로만 한다. */
export type FormOption = {
  label: string
  description: string
  preview?: string
  recommended?: '추천' | '에이전트 추천'
}

/** 질문지 질문 하나. when 은 앞쪽 single·multi 질문의 라벨에 건다. */
export type FormQuestion = {
  id: string
  header: string
  group?: string
  question: string
  detail?: string
  kind: 'single' | 'multi' | 'text'
  options?: FormOption[]
  allowOther?: boolean
  allowNote?: boolean
  placeholder?: string
  when?: { id: string; selected: string[] }
}

/** 질문지 도구의 입력. */
export type FormInput = {
  title: string
  intro?: string
  replaces?: string
  questions: FormQuestion[]
}

/** 쓰던 답. selected 는 라벨 원문(추천 접미 없음), other 는 기타 입력이나 text 질문의 답. */
export type Draft = { selected: string[]; other: string; note: string }
export type Drafts = Record<string, Draft>

export type FormPhase = 'open' | 'submitted' | 'cancelled'

/**
 * 열려 있는 입력칸 하나: 어느 질문의 어느 칸인지, 열 때마다 하나씩 오르는 세대(입력칸 key 에
 * 들어간다), 연 순간의 글(그려지는 value 로 고정된다).
 */
export type FormEditor = { id: string; field: 'other' | 'note'; gen: number; seed: string }

/** 질문지 기록 하나. 제출·취소된 기록은 묶음을 낸 자리에서 버려지므로 열린 것만 남는다. */
export type FormRecord = {
  id: string
  toolUseId: string
  form: FormInput
  drafts: Drafts
  phase: FormPhase
  /** 사람이 닫기 표시를 눌렀거나 열 때 배치되지 않아 패널 대신 상태 줄을 보이는 중. */
  hidden: boolean
  /** 펼쳐 보이는 질문의 id. 나머지 질문은 한 줄로 접힌다. */
  cursor: string
  /** 열려 있는 「기타」·「메모」 입력칸. 없으면 null. */
  editor: FormEditor | null
  /** 이 기록에서 입력칸을 연 횟수. 입력칸 key 의 세대이며, 칸을 닫아도 되돌지 않는다. */
  editorGen: number
  sessionId: string
  savedAt: number
}

/** 질문지가 읽는 사람 프롬프트의 출처 낱말(composer·bridge 등). 모르면 null. */
export type PromptOriginKind = string | null

declare module 'claude-code' {
  interface PluginState {
    'cc-cmds': {
      paneLines: PaneLines
      paneControl: PaneControl
      /** 지금 열린 질문지 기록. 없으면 null. */
      'questionForm.record': FormRecord | null
      /** 마지막 사람 프롬프트의 출처. bridge 이면 질문지를 쓸 수 없다. */
      'questionForm.lastPersonOrigin': PromptOriginKind
      /** 질문지 패널에서 포커스를 받은 요소의 key. 엔진 자신의 정지점이면 null. */
      'questionForm.focusedElement': string | null
    }
  }
}
