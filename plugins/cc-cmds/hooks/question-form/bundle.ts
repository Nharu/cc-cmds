// 답 묶음: 머리줄, 머리줄 정규식, `cc-form-answers/1` JSON, 문답 기록의
// `### 답 n` 본문과 같은 `answer` 문면. `$` 를 쓰지 않는다.

import { NOT_APPLICABLE, UNANSWERED } from './spec'
import type { Draft, Drafts, FormInput, FormOption, FormQuestion } from '../../types'

export type { Draft, Drafts }

export type FormStatus = '제출' | '취소'

export const EMPTY_DRAFT: Draft = { selected: [], other: '', note: '' }

export const HEADER_RE = /^\[cc-cmds 질문지 답\] form=(f-[0-9a-f]{8}) status=(제출|취소) /

const HEADER_MARK = '[cc-cmds 질문지 답]'

// 도장을 달 문면인가: 머리줄 표지가 어디에든 있으면 흉내다. 앞에 붙은 줄바꿈·공백이나
// 분해형(NFD) 한글로 머리줄 정규식을 비껴가도 도장이 빠지지 않게 정규화한 뒤 찾는다.
export const mimicsHeader = (text: string): boolean => text.normalize('NFC').includes(HEADER_MARK)

export function mintFormId(random: () => number = Math.random): string {
  let hex = ''
  for (let i = 0; i < 8; i++) hex += Math.floor(random() * 16).toString(16)
  return `f-${hex}`
}

// 입력칸 값은 한 줄 글이다. 엔진은 제어 문자를 품은 Button 라벨·text 자식을 그리지 않고
// 패널 전체를 자기 대체 화면으로 바꾸므로, 값을 받는 자리와 그리는 자리(Button 라벨·답
// 요약), 보내는 자리(답 묶음)에서 걸러 낸다. 줄바꿈·탭은 공백 하나로 바꾸고 나머지 제어
// 문자(C0·DEL·C1)는 뺀다.
export const inputValue = (v: string): string =>
  v.replace(/\r\n|[\r\n\t]/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, '')

export const draftOf = (drafts: Drafts, id: string): Draft => drafts[id] ?? EMPTY_DRAFT

// 고치기 전에 보관된 초안에는 제어 문자가 남아 있을 수 있으므로 거른 글로 판정한다.
export function isAnswered(q: FormQuestion, d: Draft): boolean {
  const other = inputValue(d.other).trim()
  if (q.kind === 'text') return other !== ''
  return d.selected.length > 0 || other !== ''
}

// `when` 이 가리키는 앞 질문이 보이고 그 질문에서 라벨 하나라도 골랐을 때만 보인다.
export function isVisible(form: FormInput, drafts: Drafts, q: FormQuestion): boolean {
  if (!q.when) return true
  const when = q.when
  const target = form.questions.find(x => x.id === when.id)
  if (!target || !isVisible(form, drafts, target)) return false
  return draftOf(drafts, target.id).selected.some(s => when.selected.includes(s))
}

export function counts(form: FormInput, drafts: Drafts): { answered: number; total: number } {
  const visible = form.questions.filter(q => isVisible(form, drafts, q))
  return { answered: visible.filter(q => isAnswered(q, draftOf(drafts, q.id))).length, total: visible.length }
}

// 문답 기록 `### 답 n` 본문. 라벨은 받은 그대로 쓰고 추천 접미를 붙이지 않는다 — 추천은
// 묶음의 `recommended` 가 따로 싣는다. single 은 고른 라벨,
// multi 는 한 줄에 하나, 선택지 대신 쓴 자유 입력은 축자, multi 라벨 옆의
// 자유 입력은 마지막 줄 `자유 입력:`, 메모는 맨 끝 `메모:`, 답이 없으면 `미답`.
export function answerBody(q: FormQuestion, d: Draft): string {
  const lines: string[] = []
  const other = d.other.trim() === '' ? '' : d.other
  if (!isAnswered(q, d)) {
    lines.push(UNANSWERED)
  } else if (q.kind === 'text') {
    lines.push(other)
  } else if (q.kind === 'single') {
    lines.push(d.selected.length > 0 ? d.selected[0] : other)
  } else {
    for (const s of d.selected) lines.push(s)
    if (other !== '') lines.push(d.selected.length > 0 ? `자유 입력: ${other}` : other)
  }
  if (d.note.trim() !== '') lines.push(`메모: ${d.note}`)
  return lines.join('\n')
}

export type BundleAnswer = {
  id: string
  header: string
  group?: string
  question: string
  kind: FormQuestion['kind']
  options: string[]
  recommended?: { label: string; by: NonNullable<FormOption['recommended']> }[]
  state: '답' | '미답' | '해당 없음'
  selected: string[]
  other: string
  note: string
  answer: string
}

export type BundleJson = { schema: 'cc-form-answers/1'; form: string; status: FormStatus; answers: BundleAnswer[] }

export function bundleJson(formId: string, status: FormStatus, form: FormInput, drafts: Drafts): BundleJson {
  const answers = form.questions.map((q): BundleAnswer => {
    const raw = draftOf(drafts, q.id)
    const d: Draft = { ...raw, other: inputValue(raw.other), note: inputValue(raw.note) }
    const options = (q.options ?? []).map(o => o.label)
    const recommended = (q.options ?? []).flatMap(o => (o.recommended ? [{ label: o.label, by: o.recommended }] : []))
    const base = {
      id: q.id,
      header: q.header,
      ...(q.group ? { group: q.group } : {}),
      question: q.question,
      kind: q.kind,
      options,
      ...(recommended.length > 0 ? { recommended } : {}),
    }
    if (!isVisible(form, drafts, q)) {
      return { ...base, state: NOT_APPLICABLE, selected: [], other: '', note: '', answer: '' }
    }
    return {
      ...base,
      state: isAnswered(q, d) ? '답' : UNANSWERED,
      selected: [...d.selected],
      other: d.other,
      note: d.note,
      answer: answerBody(q, d),
    }
  })
  return { schema: 'cc-form-answers/1', form: formId, status, answers }
}

export function headerLine(formId: string, status: FormStatus, answered: number, total: number): string {
  return `[cc-cmds 질문지 답] form=${formId} status=${status} 답=${answered}/${total}`
}

export function bundleText(formId: string, status: FormStatus, form: FormInput, drafts: Drafts): string {
  const { answered, total } = counts(form, drafts)
  const json = JSON.stringify(bundleJson(formId, status, form, drafts))
  return `${headerLine(formId, status, answered, total)}\n\`\`\`json\n${json}\n\`\`\``
}

export function parseHeader(text: string): { form: string; status: FormStatus } | undefined {
  const m = HEADER_RE.exec(text)
  return m ? { form: m[1], status: m[2] as FormStatus } : undefined
}
