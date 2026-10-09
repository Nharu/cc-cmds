// 답 묶음: 머리줄, 머리줄 정규식, `cc-form-answers/1` JSON, 문답 기록의
// `### 답 n` 본문과 같은 `answer` 문면. `$` 를 쓰지 않는다.

import { NOT_APPLICABLE, UNANSWERED, presentedLabel } from './spec'
import type { Draft, Drafts, FormInput, FormQuestion } from '../../types'

export type { Draft, Drafts }

export type FormStatus = '제출' | '취소'

export const EMPTY_DRAFT: Draft = { selected: [], other: '', note: '' }

export const HEADER_RE = /^\[cc-cmds 질문지 답\] form=(f-[0-9a-f]{8}) status=(제출|취소) /

export function mintFormId(random: () => number = Math.random): string {
  let hex = ''
  for (let i = 0; i < 8; i++) hex += Math.floor(random() * 16).toString(16)
  return `f-${hex}`
}

export const draftOf = (drafts: Drafts, id: string): Draft => drafts[id] ?? EMPTY_DRAFT

export function isAnswered(q: FormQuestion, d: Draft): boolean {
  if (q.kind === 'text') return d.other.trim() !== ''
  return d.selected.length > 0 || d.other.trim() !== ''
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

function presentedOf(q: FormQuestion, label: string): string {
  const o = (q.options ?? []).find(x => x.label === label)
  return o ? presentedLabel(o) : label
}

// 문답 기록 `### 답 n` 본문. single 은 고른 라벨을 제시한 그대로(접미 포함),
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
    lines.push(d.selected.length > 0 ? presentedOf(q, d.selected[0]) : other)
  } else {
    for (const s of d.selected) lines.push(presentedOf(q, s))
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
  state: '답' | '미답' | '해당 없음'
  selected: string[]
  other: string
  note: string
  answer: string
}

export type BundleJson = { schema: 'cc-form-answers/1'; form: string; status: FormStatus; answers: BundleAnswer[] }

export function bundleJson(formId: string, status: FormStatus, form: FormInput, drafts: Drafts): BundleJson {
  const answers = form.questions.map((q): BundleAnswer => {
    const d = draftOf(drafts, q.id)
    const options = (q.options ?? []).map(presentedLabel)
    const base = { id: q.id, header: q.header, ...(q.group ? { group: q.group } : {}), question: q.question, kind: q.kind, options }
    if (!isVisible(form, drafts, q)) {
      return { ...base, state: NOT_APPLICABLE, selected: [], other: '', note: '', answer: '' }
    }
    return {
      ...base,
      state: isAnswered(q, d) ? '답' : UNANSWERED,
      selected: d.selected.map(s => presentedOf(q, s)),
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
