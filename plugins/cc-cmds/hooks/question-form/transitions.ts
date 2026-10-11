// 질문지 수명 주기의 순수 전이. 훅과 처리기는 이 함수들이 돌려준 기록을
// `$.state` 에 쓰고, 패널·상태 줄·제출·포커스 같은 바깥 일은 스스로 한다.
// 시험 키트는 사람의 닫기를 일으킬 수 없으므로 전이는 여기서 따로 시험한다.

import { draftOf, inputValue, isVisible } from './bundle'
import { holdsRefusedControl } from './validate'
import type { Draft, Drafts, FormEditor, FormInput, FormPhase, FormRecord } from '../../types'

export type { FormEditor, FormPhase, FormRecord }

export const STORE_TTL_MS = 7 * 24 * 60 * 60 * 1000

export const isOpen = (r: FormRecord | undefined): r is FormRecord => r !== undefined && r.phase === 'open'

// 도구 호출이 무엇이 되는가: 열린 질문지가 있으면 replaces 일 때만 갈아 끼우고
// 아니면 BUSY. 아무것도 없으면 새로 연다(배너는 새로 연 경우만).
export type CallDecision = { kind: 'busy'; id: string } | { kind: 'replace' } | { kind: 'new' }

export function decideCall(current: FormRecord | undefined, replaces: string | undefined): CallDecision {
  if (isOpen(current)) return replaces === current.id ? { kind: 'replace' } : { kind: 'busy', id: current.id }
  return { kind: 'new' }
}

// 갈아 끼울 때 id·종류·라벨 집합이 같은 질문만 쓰던 답을 이어 받는다.
export function carryDrafts(prev: FormInput, prevDrafts: Drafts, next: FormInput): Drafts {
  const out: Drafts = {}
  for (const q of next.questions) {
    const old = prev.questions.find(x => x.id === q.id)
    const d = prevDrafts[q.id]
    if (!old || !d || old.kind !== q.kind) continue
    const a = (old.options ?? []).map(o => o.label).sort()
    const b = (q.options ?? []).map(o => o.label).sort()
    if (a.length === b.length && a.every((l, i) => l === b[i])) out[q.id] = d
  }
  return out
}

export function openRecord(args: {
  id: string
  toolUseId: string
  form: FormInput
  drafts: Drafts
  sessionId: string
  now: number
}): FormRecord {
  const { now, ...rest } = args
  const rec: FormRecord = { ...rest, phase: 'open', hidden: false, cursor: '', editor: null, editorGen: 0, savedAt: now }
  return land(settleCursor(rec))
}

// 열기 결과 반영: 배치되지 않았으면 숨김(상태 줄).
export const placed = (r: FormRecord, isPlaced: boolean): FormRecord => ({ ...r, hidden: !isPlaced })

// 보이는 질문의 id 를 차례로.
export const visibleIds = (r: FormRecord): string[] =>
  r.form.questions.filter(q => isVisible(r.form, r.drafts, q)).map(q => q.id)

export const questionOf = (r: FormRecord, id: string) => r.form.questions.find(q => q.id === id)

// 커서가 보이지 않는 질문을 가리키면(when 의 앞 답이 바뀌었거나 보관에서 되살렸거나)
// 가장 가까운 앞쪽의 보이는 질문으로, 그것도 없으면 첫 질문으로 옮기고 입력칸을 닫는다.
export function settleCursor(r: FormRecord): FormRecord {
  const ids = visibleIds(r)
  if (ids.includes(r.cursor)) return r
  const order = r.form.questions.map(q => q.id)
  const at = order.indexOf(r.cursor)
  const before = at < 0 ? [] : ids.filter(id => order.indexOf(id) < at)
  return { ...r, cursor: before[before.length - 1] ?? ids[0] ?? r.cursor, editor: null }
}

// 커서가 답 없는 text 질문에 놓이면 그 답 칸을 연다. 답이 있으면 답 줄을 보인다.
export function land(r: FormRecord): FormRecord {
  const q = questionOf(r, r.cursor)
  if (!q || q.kind !== 'text') return r
  if (r.editor && r.editor.id === r.cursor) return r
  return inputValue(draftOf(r.drafts, r.cursor).other).trim() === '' ? openEditor(r, r.cursor, 'other') : r
}

// 커서 이동. 보이지 않는 질문으로는 가지 않는다.
export function jump(r: FormRecord, id: string): FormRecord {
  if (!visibleIds(r).includes(id) || id === r.cursor) return r
  return land({ ...r, cursor: id, editor: null })
}

// 다음·이전 보이는 질문. 끝이면 undefined.
export function advance(r: FormRecord): FormRecord | undefined {
  const ids = visibleIds(r)
  const next = ids[ids.indexOf(r.cursor) + 1]
  return next === undefined ? undefined : jump(r, next)
}

export function retreat(r: FormRecord): FormRecord | undefined {
  const ids = visibleIds(r)
  const at = ids.indexOf(r.cursor)
  const prev = at > 0 ? ids[at - 1] : undefined
  return prev === undefined ? undefined : jump(r, prev)
}

// 입력칸 열기. 세대가 하나 오르고 그때의 답이 씨앗이 된다 — 입력칸의 key 는 세대마다
// 다르고 그려지는 value 는 씨앗으로 고정이라, 표면이 Enter 뒤에 비운 글이 다시
// 열린 칸에 묻어 오지 않고, 치는 동안의 다시 그리기가 치던 글을 되돌리지 않는다.
// 세대는 기록 안에서 되돌지 않는다: 표면은 한 번 쓴 key 의 빈 글을 패널이 사는 동안 기억한다.
export function openEditor(r: FormRecord, id: string, field: FormEditor['field']): FormRecord {
  const gen = r.editorGen + 1
  const d = draftOf(r.drafts, id)
  return { ...r, cursor: id, editor: { id, field, gen, seed: field === 'note' ? d.note : d.other }, editorGen: gen }
}

export const closeEditor = (r: FormRecord): FormRecord => (r.editor ? { ...r, editor: null } : r)

function withDraft(r: FormRecord, id: string, patch: Partial<Draft>): FormRecord {
  return { ...r, drafts: { ...r.drafts, [id]: { ...draftOf(r.drafts, id), ...patch } } }
}

// 전이 뒤 포커스가 갈 곳: 그대로, 다음 질문의 첫 조작부, 질문이 끝나 [제출].
export type Move = 'stay' | 'next' | 'end'

function forward(r: FormRecord): { record: FormRecord; move: Move } {
  const next = advance(r)
  return next ? { record: next, move: 'next' } : { record: r, move: 'end' }
}

// 선택지 누름. single 은 고르면 기타를 비우고 다음 질문으로, 다시 누르면 풀린다.
// multi 는 켜고 끈다. 그 질문의 기타 입력칸이 열려 있었으면 닫는다.
export function choose(r: FormRecord, id: string, label: string): { record: FormRecord; move: Move } {
  const q = questionOf(r, id)
  const d = draftOf(r.drafts, id)
  if (!q || q.kind === 'text') return { record: r, move: 'stay' }
  const base = r.editor?.id === id && r.editor.field === 'other' ? closeEditor(r) : r
  if (q.kind === 'multi') {
    const selected = d.selected.includes(label) ? d.selected.filter(s => s !== label) : [...d.selected, label]
    return { record: settleCursor(withDraft(base, id, { selected })), move: 'stay' }
  }
  if (d.selected.includes(label)) return { record: settleCursor(withDraft(base, id, { selected: [] })), move: 'stay' }
  return forward(settleCursor(withDraft(base, id, { selected: [label], other: '' })))
}

// 입력칸의 글이 바뀔 때마다: 답을 바로 적는다(확정 없이 나가도 답으로 남는다).
// single 의 기타에 글이 있으면 고른 선택지는 풀린다. 초안에는 거른 글만 적는다.
export function typeText(r: FormRecord, id: string, field: FormEditor['field'], value: string): FormRecord {
  value = inputValue(value)
  if (field === 'note') return withDraft(r, id, { note: value })
  const q = questionOf(r, id)
  const patch: Partial<Draft> = q?.kind === 'single' && value.trim() !== '' ? { other: value, selected: [] } : { other: value }
  return settleCursor(withDraft(r, id, patch))
}

// Enter 로 확정: 답을 적고 입력칸을 닫는다. single 의 기타와 text 의 답은 글이 있으면
// 다음 질문으로 간다. 메모와 multi 의 기타는 그 자리에 남는다.
export function commitText(r: FormRecord, id: string, field: FormEditor['field'], value: string): { record: FormRecord; move: Move } {
  const typed = typeText(r, id, field, value)
  const record = typed.editor?.id === id && typed.editor.field === field ? closeEditor(typed) : typed
  const q = questionOf(record, id)
  const moves = field === 'other' && inputValue(value).trim() !== '' && (q?.kind === 'single' || q?.kind === 'text')
  return moves ? forward(record) : { record, move: 'stay' }
}

// [제출]: CAS open→submitted. 이미 소비된 기록이면 undefined(두 번째 누름 무시).
export function submit(r: FormRecord | undefined): FormRecord | undefined {
  if (!isOpen(r)) return undefined
  return { ...r, phase: 'submitted', hidden: false }
}

// [답 없이 닫기]: CAS open→cancelled.
export function cancel(r: FormRecord | undefined): FormRecord | undefined {
  if (!isOpen(r)) return undefined
  return { ...r, phase: 'cancelled' }
}

// 사람의 닫기 표시: 열린 질문지는 숨길 뿐 기록과 BUSY 를 유지한다.
export function personClose(r: FormRecord | undefined): { record: FormRecord | undefined; showStatus: boolean } {
  if (isOpen(r)) return { record: { ...r, hidden: true }, showStatus: true }
  return { record: undefined, showStatus: false }
}

// /question-form: 열린 질문지를 다시 보인다. 없으면 undefined(알림).
export function reopen(r: FormRecord | undefined): FormRecord | undefined {
  return isOpen(r) ? { ...r, hidden: false } : undefined
}

export const expired = (stored: FormRecord, now: number) => now - stored.savedAt > STORE_TTL_MS

// 보관에서 되살릴지: 같은 세션의 열린 기록만 되살린다. now 를 주면 7일이 지난 기록은
// 같은 세션의 것이어도 되살리지 않는다. 앞 판이 보관한 기록에는 커서와 입력칸이
// 없으므로 첫 질문에서 시작하게 채운다. 모델 입력에 엔진이 거부하는 제어 문자가 든
// 기록(검사가 생기기 전에 열린 것)은 그려도 패널이 깨지므로 되살리지 않는다.
export function restorable(stored: FormRecord | undefined, sessionId: string, now?: number): FormRecord | undefined {
  if (!isOpen(stored) || stored.sessionId !== sessionId) return undefined
  if (now !== undefined && expired(stored, now)) return undefined
  if (holdsRefusedControl(stored.form)) return undefined
  return land(settleCursor({ ...stored, cursor: stored.cursor ?? '', editor: stored.editor ?? null, editorGen: stored.editorGen ?? 0 }))
}
