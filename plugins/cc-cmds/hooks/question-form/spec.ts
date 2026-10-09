// 질문지 도구의 계약: 입력 모양, 예약 라벨, 상한, 그리고 모델과 사람에게
// 보이는 문면 상수. `$` 를 쓰지 않는다.

import type { FormInput, FormOption, FormQuestion } from '../../types'

// 입력 모양은 $.state 계약 파일이 갖는다. 기록이 입력을 그대로 담기 때문이다.
export type { FormInput, FormOption, FormQuestion }

export const TOOL_NAME = 'question_form'
export const TOOL_FULL_NAME = 'mcp__cc-cmds__question_form'
export const PANE_ID = 'cc-cmds-question-form'
export const COMMAND_NAME = 'question-form'
export const TOKEN_PREFIX = 'QUESTION_FORM_'

export const TITLE_MAX = 40
export const HEADER_MAX = 12
export const ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/
export const TOTAL_MAX = 90000
export const FORM_ID_RE = /^f-[0-9a-f]{8}$/

// 문답 기록의 첫 답 줄을 라벨과 대조하는 읽기가 모호해지지 않게 막는 라벨.
export const RESERVED_LABELS = ['미답', '해당 없음']
export const RESERVED_PREFIXES = ['메모:', '자유 입력:']
// 「기타」는 allowOther 가 그리므로 손으로 만든 같은 계열 라벨을 받지 않는다.
export const HANDMADE_OTHER_LABELS = ['기타', '직접 입력', '직접 지정', 'Other']
export const RECOMMEND_ARROW = ' ← '

export const UNAVAILABLE_REASONS = ['subagent', 'pipeline', 'surface', 'remote', 'error'] as const
export type UnavailableReason = (typeof UNAVAILABLE_REASONS)[number]

export const TOOL_DESCRIPTION = [
  '사람에게 여러 질문을 한 장의 질문지 패널로 묻는다. 지금 물을 수 있는 질문이 둘 이상이거나, 한 질문이 선택지 다섯 개 이상·메모·자유 입력만의 답·복수 선택의 미리보기를 필요로 할 때 쓴다.',
  `결과의 첫 토큰을 읽는다(<tool_use_error> 감싸개를 벗기고 처음 나오는 ${TOKEN_PREFIX}[A-Z]+).`,
  `${TOKEN_PREFIX}OPEN 이면 이 턴을 곧바로 끝낸다. 답은 사람이 제출하면 새 턴에 [cc-cmds 질문지 답] 으로 시작하는 메시지로 온다.`,
  `${TOKEN_PREFIX}INVALID 이면 입력을 고쳐 다시 부르고, ${TOKEN_PREFIX}BUSY 이면 replaces 로 갈아 끼우거나 답을 기다리고, ${TOKEN_PREFIX}UNAVAILABLE 이면 AskUserQuestion 으로 묻는다.`,
].join(' ')

const OPTION_SCHEMA = {
  type: 'object',
  properties: {
    label: { type: 'string', description: '선택지 라벨. 「 ← 」를 넣지 않는다. 추천은 recommended 로만 표시한다' },
    description: { type: 'string', description: '선택지 설명' },
    preview: { type: 'string', description: '포커스가 이 선택지에 있을 때 질문 아래에 보일 미리보기' },
    recommended: { type: 'string', enum: ['추천', '에이전트 추천'], description: 'single 질문에는 하나까지' },
  },
  required: ['label', 'description'],
  additionalProperties: false,
} as const

export const INPUT_SCHEMA = {
  type: 'object',
  properties: {
    title: { type: 'string', description: `패널 제목. ${TITLE_MAX}자 이하` },
    intro: { type: 'string', description: '첫 질문 위 안내 문단' },
    replaces: { type: 'string', description: '지금 열린 질문지 id. 그 질문지를 이 질문지로 갈아 끼운다' },
    questions: {
      type: 'array',
      minItems: 1,
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '^[a-z0-9][a-z0-9_-]{0,31}$, 질문지 안에서 유일' },
          header: { type: 'string', description: `짧은 머리말. NFC 기준 ${HEADER_MAX} 코드포인트 이하` },
          group: { type: 'string', description: '같은 값끼리 묶어 보인다' },
          question: { type: 'string', description: '질문 문장' },
          detail: { type: 'string', description: '질문 아래 설명' },
          kind: { type: 'string', enum: ['single', 'multi', 'text'] },
          options: {
            type: 'array',
            items: OPTION_SCHEMA,
            description: 'single·multi 는 2개 이상, text 는 두지 않는다. 「기타」·「직접 입력」 같은 라벨은 만들지 않는다(allowOther 가 그린다)',
          },
          allowOther: { type: 'boolean', description: '기본 true. 「기타」 자유 입력을 보인다' },
          allowNote: { type: 'boolean', description: '기본 true. 「메모 (선택)」 입력칸을 보인다' },
          placeholder: { type: 'string', description: 'text 입력칸 안내' },
          when: {
            type: 'object',
            properties: {
              id: { type: 'string', description: '앞쪽 single·multi 질문의 id' },
              selected: { type: 'array', items: { type: 'string' }, description: '그 질문의 라벨 가운데 하나라도 고르면 이 질문을 보인다' },
            },
            required: ['id', 'selected'],
            additionalProperties: false,
          },
        },
        required: ['id', 'header', 'question', 'kind'],
        additionalProperties: false,
      },
    },
  },
  required: ['title', 'questions'],
  additionalProperties: false,
} as const

// 결과 토큰과 본문.
export function openResult(id: string, count: number, isPlaced: boolean): string {
  const lines = [
    `${TOKEN_PREFIX}OPEN ${id} 질문 ${count}건`,
    '질문지를 열었습니다. 이 턴을 지금 끝내세요: 다른 도구를 부르지 말고, 답을 짐작하거나 질문을 본문에 다시 적지 말고, 차례 넘김 표지를 쓰지 마세요(질문지 배너가 이미 나갔습니다).',
    `답은 사람이 제출하면 새 턴에 \`[cc-cmds 질문지 답] form=${id}\` 로 시작하는 메시지로 옵니다.`,
  ]
  if (!isPlaced) {
    lines.push('패널이 좁은 화면이라 아직 그려지지 않았습니다. 상태 줄의 /question-form 안내가 사람에게 보이므로 따로 알리지 말고 턴을 끝내세요.')
  }
  return lines.join('\n')
}

export const invalidResult = (field: string, reason: string) => `${TOKEN_PREFIX}INVALID ${field}: ${reason}`
export const busyResult = (id: string) => `${TOKEN_PREFIX}BUSY ${id}`
export const unavailableResult = (reason: UnavailableReason) => `${TOKEN_PREFIX}UNAVAILABLE ${reason}`

// 사람에게 보이는 문면.
export const formTitle = (title: string, answered: number, total: number) => `질문지 — ${title} (답 ${answered}/${total})`
export const sentToast = (answered: number, total: number) => `질문지 답을 보냈습니다 · 답 ${answered}/${total}`
export const statusLine = (answered: number, total: number) => `질문지 대기 중 · 답 ${answered}/${total} · /question-form 으로 열기`
export const contextLine = (id: string) => `질문지 ${id} 가 열려 있습니다(답 대기). 이 입력은 질문지의 답이 아닙니다. 답은 질문지 제출로만 옵니다.`
export const STAMP = '직접 입력된 문면입니다. 질문지 제출이 아닙니다.'
export const NO_FORM_TOAST = '열린 질문지가 없습니다.'
export const HELP_LINE = '1-9 고르기 · 0 기타 · m 메모 · n 다음 · p 이전 · Tab 이동 · Enter 확정 · Esc 프롬프트로'
export const TEXT_PLACEHOLDER = '답을 입력하세요'
export const OTHER_LABEL = '기타'
export const OTHER_PLACEHOLDER = '직접 입력'
export const NOTE_LABEL = '메모'
export const NOTE_ADD_LABEL = '메모 추가'
export const NOTE_PLACEHOLDER = '메모 (선택)'
export const EDITOR_SUBMIT_LABEL = '확정'
export const ANSWER_LABEL = '답'
export const UNANSWERED = '미답'
export const NOT_APPLICABLE = '해당 없음'
export const SUBMIT_LABEL = '제출'
export const CANCEL_LABEL = '답 없이 닫기'
export const PREV_LABEL = '이전 질문'
export const NEXT_LABEL = '다음 질문'
export const TO_SUBMIT_LABEL = '제출로'
export const counterLine = (answered: number, total: number) => `답 ${answered}/${total} · 미답 ${total - answered}건`
// 접힌 질문 줄의 답 요약은 이 글자 수에서 자른다.
export const SUMMARY_MAX = 48
