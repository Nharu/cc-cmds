// 질문지 수명 주기의 순수 전이. 훅과 처리기는 이 함수들이 돌려준 기록을
// `$.state` 에 쓰고, 패널·상태 줄·제출 같은 바깥 일은 스스로 한다.
// 시험 키트는 사람의 닫기를 일으킬 수 없으므로 전이는 여기서 따로 시험한다.

import type { Drafts, FormInput, FormPhase, FormRecord } from '../../types'

export type { FormPhase, FormRecord }

export const STORE_TTL_MS = 7 * 24 * 60 * 60 * 1000

export const isOpen = (r: FormRecord | undefined): r is FormRecord => r !== undefined && r.phase === 'open'
export const isReceipt = (r: FormRecord | undefined): r is FormRecord => r !== undefined && r.phase === 'submitted'

// 도구 호출이 무엇이 되는가: 열린 질문지가 있으면 replaces 일 때만 갈아 끼우고
// 아니면 BUSY. 영수증이거나 아무것도 없으면 새로 연다(배너는 새로 연 경우만).
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
  return { ...rest, phase: 'open', hidden: false, otherOpen: [], receiptTurns: 0, savedAt: now }
}

// 열기 결과 반영: 배치되지 않았으면 숨김(상태 줄).
export const placed = (r: FormRecord, isPlaced: boolean): FormRecord => ({ ...r, hidden: !isPlaced })

// [제출]: CAS open→submitted. 이미 소비된 기록이면 undefined(두 번째 누름 무시).
// 사람의 턴이 진행 중이면 그 턴의 turn.complete 를 하나 더 지나야 묶음 턴이다.
export function submit(r: FormRecord | undefined, turnBusy: boolean): FormRecord | undefined {
  if (!isOpen(r)) return undefined
  return { ...r, phase: 'submitted', hidden: false, receiptTurns: turnBusy ? 2 : 1 }
}

// [답 없이 닫기]: CAS open→cancelled. 처리기가 묶음을 내고 패널을 닫은 뒤 기록을 버린다.
export function cancel(r: FormRecord | undefined): FormRecord | undefined {
  if (!isOpen(r)) return undefined
  return { ...r, phase: 'cancelled' }
}

// 사람의 닫기 표시: 열린 질문지는 숨길 뿐 기록과 BUSY 를 유지한다. 영수증은 버린다.
export function personClose(r: FormRecord | undefined): { record: FormRecord | undefined; showStatus: boolean } {
  if (isOpen(r)) return { record: { ...r, hidden: true }, showStatus: true }
  return { record: undefined, showStatus: false }
}

// /question-form: 열린 질문지를 다시 보인다. 없으면 undefined(알림).
export function reopen(r: FormRecord | undefined): FormRecord | undefined {
  return isOpen(r) ? { ...r, hidden: false } : undefined
}

// 주 루프의 turn.complete: 영수증이면 남은 턴을 하나 줄이고 0 이면 닫는다.
export function turnComplete(r: FormRecord | undefined): { record: FormRecord | undefined; closeReceipt: boolean } {
  if (!isReceipt(r)) return { record: r, closeReceipt: false }
  const left = r.receiptTurns - 1
  if (left <= 0) return { record: undefined, closeReceipt: true }
  return { record: { ...r, receiptTurns: left }, closeReceipt: false }
}

export const expired = (stored: FormRecord, now: number) => now - stored.savedAt > STORE_TTL_MS

// 보관에서 되살릴지: 같은 세션의 열린 기록만 되살린다. now 를 주면 7일이 지난 기록은
// 같은 세션의 것이어도 되살리지 않는다.
export function restorable(stored: FormRecord | undefined, sessionId: string, now?: number): FormRecord | undefined {
  if (!isOpen(stored) || stored.sessionId !== sessionId) return undefined
  return now !== undefined && expired(stored, now) ? undefined : stored
}
