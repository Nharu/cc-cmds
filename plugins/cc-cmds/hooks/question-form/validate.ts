// 질문지 입력 전체 검증. 엔진은 입력 스키마를 강제하지 않으므로 이 파일이
// 유일한 검사다. 첫 위반 하나를 `QUESTION_FORM_INVALID <칸>: <사유>` 로 돌려준다.

import {
  HANDMADE_OTHER_LABELS,
  HEADER_MAX,
  ID_RE,
  RECOMMEND_ARROW,
  RESERVED_LABELS,
  RESERVED_PREFIXES,
  TITLE_MAX,
  TOTAL_MAX,
  invalidResult,
} from './spec'
import type { FormInput } from './spec'

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const isStr = (v: unknown): v is string => typeof v === 'string'
const codePoints = (s: string) => [...s].length

// 입력 안 모든 문자열의 글자 수 합.
export function totalChars(v: unknown): number {
  if (isStr(v)) return codePoints(v)
  if (Array.isArray(v)) return v.reduce((n: number, x) => n + totalChars(x), 0)
  if (isObj(v)) return Object.values(v).reduce((n: number, x) => n + totalChars(x), 0)
  return 0
}

function labelProblem(label: string): string | undefined {
  if (label.includes(RECOMMEND_ARROW.trim())) return '라벨에 「←」를 넣지 않습니다. 추천은 recommended 로 표시합니다'
  if (HANDMADE_OTHER_LABELS.includes(label.trim())) return `「${label.trim()}」 라벨은 만들지 않습니다. allowOther 가 기타 입력을 그립니다`
  if (RESERVED_LABELS.includes(label.trim())) return `「${label.trim()}」는 예약 라벨입니다`
  for (const p of RESERVED_PREFIXES) if (label.trim().startsWith(p)) return `「${p}」로 시작하는 라벨은 예약돼 있습니다`
  return undefined
}

// openId: 지금 열린(제출·취소되지 않은) 질문지 id. 없으면 undefined.
export function validateForm(input: unknown, openId: string | undefined): string | undefined {
  const bad = invalidResult
  if (!isObj(input)) return bad('input', '객체가 아닙니다')
  if (!isStr(input.title) || input.title.trim() === '') return bad('title', '필수입니다')
  if (codePoints(input.title) > TITLE_MAX) return bad('title', `${TITLE_MAX}자를 넘습니다`)
  if (input.intro !== undefined && !isStr(input.intro)) return bad('intro', '문자열이 아닙니다')
  if (input.replaces !== undefined) {
    if (!isStr(input.replaces)) return bad('replaces', '문자열이 아닙니다')
    if (input.replaces !== openId) return bad('replaces', openId ? `열린 질문지 id 는 ${openId} 입니다` : '열린 질문지가 없습니다')
  }
  if (!Array.isArray(input.questions) || input.questions.length === 0) return bad('questions', '1개 이상이어야 합니다')

  const seen = new Map<string, { index: number; kind: string; labels: string[] }>()
  for (let i = 0; i < input.questions.length; i++) {
    const q = input.questions[i]
    const at = `questions[${i}]`
    if (!isObj(q)) return bad(at, '객체가 아닙니다')
    if (!isStr(q.id) || !ID_RE.test(q.id)) return bad(`${at}.id`, '^[a-z0-9][a-z0-9_-]{0,31}$ 에 맞지 않습니다')
    if (seen.has(q.id)) return bad(`${at}.id`, `「${q.id}」가 겹칩니다`)
    if (!isStr(q.header) || q.header.trim() === '') return bad(`${at}.header`, '필수입니다')
    if (codePoints(q.header.normalize('NFC')) > HEADER_MAX) return bad(`${at}.header`, `NFC 기준 ${HEADER_MAX} 코드포인트를 넘습니다`)
    if (!isStr(q.question) || q.question.trim() === '') return bad(`${at}.question`, '필수입니다')
    for (const k of ['group', 'detail', 'placeholder'] as const) {
      if (q[k] !== undefined && !isStr(q[k])) return bad(`${at}.${k}`, '문자열이 아닙니다')
    }
    for (const k of ['allowOther', 'allowNote'] as const) {
      if (q[k] !== undefined && typeof q[k] !== 'boolean') return bad(`${at}.${k}`, '참·거짓 값이 아닙니다')
    }
    if (q.kind !== 'single' && q.kind !== 'multi' && q.kind !== 'text') return bad(`${at}.kind`, 'single · multi · text 가운데 하나여야 합니다')

    const labels: string[] = []
    if (q.kind === 'text') {
      if (q.options !== undefined && (!Array.isArray(q.options) || q.options.length > 0)) return bad(`${at}.options`, 'text 질문에는 선택지를 두지 않습니다')
    } else {
      if (!Array.isArray(q.options) || q.options.length < 2) return bad(`${at}.options`, `${q.kind} 질문은 선택지가 2개 이상이어야 합니다`)
      let recommended = 0
      for (let j = 0; j < q.options.length; j++) {
        const o = q.options[j]
        const oat = `${at}.options[${j}]`
        if (!isObj(o)) return bad(oat, '객체가 아닙니다')
        if (!isStr(o.label) || o.label.trim() === '') return bad(`${oat}.label`, '필수입니다')
        if (!isStr(o.description)) return bad(`${oat}.description`, '필수입니다')
        if (o.preview !== undefined && !isStr(o.preview)) return bad(`${oat}.preview`, '문자열이 아닙니다')
        const problem = labelProblem(o.label)
        if (problem) return bad(`${oat}.label`, problem)
        if (labels.includes(o.label)) return bad(`${oat}.label`, `「${o.label}」가 겹칩니다`)
        labels.push(o.label)
        if (o.recommended !== undefined) {
          if (o.recommended !== '추천' && o.recommended !== '에이전트 추천') return bad(`${oat}.recommended`, '「추천」이나 「에이전트 추천」이어야 합니다')
          recommended++
        }
      }
      if (q.kind === 'single' && recommended > 1) return bad(`${at}.options`, 'single 질문에 추천이 둘 이상입니다')
    }

    if (q.when !== undefined) {
      const w = q.when
      if (!isObj(w) || !isStr(w.id) || !Array.isArray(w.selected) || w.selected.length === 0 || !w.selected.every(isStr)) {
        return bad(`${at}.when`, '{id, selected[]} 모양이어야 합니다')
      }
      const target = seen.get(w.id)
      if (!target) return bad(`${at}.when`, `「${w.id}」는 앞쪽 질문이 아닙니다`)
      if (target.kind === 'text') return bad(`${at}.when`, `「${w.id}」는 single·multi 질문이 아닙니다`)
      const missing = (w.selected as string[]).find(s => !target.labels.includes(s))
      if (missing !== undefined) return bad(`${at}.when`, `「${w.id}」에 「${missing}」 라벨이 없습니다`)
    }
    seen.set(q.id, { index: i, kind: q.kind, labels })
  }

  if (totalChars(input) > TOTAL_MAX) return bad('input', `글자 총량이 ${TOTAL_MAX}자를 넘습니다`)
  return undefined
}

// 검증을 통과한 입력에 기본값을 채운다.
export function normalizeForm(input: FormInput): FormInput {
  return {
    ...input,
    questions: input.questions.map(q => ({
      ...q,
      options: q.kind === 'text' ? [] : q.options ?? [],
      allowOther: q.allowOther ?? true,
      allowNote: q.allowNote ?? true,
    })),
  }
}
