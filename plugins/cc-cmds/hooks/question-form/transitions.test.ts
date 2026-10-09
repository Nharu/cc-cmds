import { describe, expect, test } from 'claude-code/testing'

import {
  STORE_TTL_MS,
  cancel,
  carryDrafts,
  decideCall,
  expired,
  openRecord,
  personClose,
  placed,
  reopen,
  restorable,
  submit,
  turnComplete,
} from './transitions'
import type { FormInput } from './spec'

const opt = (label: string) => ({ label, description: '' })
const form: FormInput = {
  title: '시험',
  questions: [
    { id: 'a', header: '가', question: '?', kind: 'single', options: [opt('x'), opt('y')] },
    { id: 'b', header: '나', question: '?', kind: 'multi', options: [opt('p'), opt('q')] },
    { id: 'c', header: '다', question: '?', kind: 'text' },
  ],
}
const rec = () => openRecord({ id: 'f-00000001', toolUseId: 'tu1', form, drafts: {}, sessionId: 'sid', now: 1000 })

describe('수명 주기', () => {
  test('열린 질문지: replaces 없으면 BUSY, 같은 id 면 갈아 끼우기, 없거나 영수증이면 새로', () => {
    expect(decideCall(undefined, undefined)).toEqual({ kind: 'new' })
    expect(decideCall(rec(), undefined)).toEqual({ kind: 'busy', id: 'f-00000001' })
    expect(decideCall(rec(), 'f-00000001')).toEqual({ kind: 'replace' })
    expect(decideCall(submit(rec(), false), undefined)).toEqual({ kind: 'new' })
  })

  test('미배치면 숨김으로 시작한다', () => {
    expect(placed(rec(), false).hidden).toBe(true)
    expect(placed(rec(), true).hidden).toBe(false)
  })

  test('[제출] CAS: open→submitted, 두 번째는 무시', () => {
    const s = submit(rec(), false)
    expect(s?.phase).toBe('submitted')
    expect(submit(s, false)).toBeUndefined()
    expect(cancel(s)).toBeUndefined()
  })

  test('[답 없이 닫기] CAS: open→cancelled, 두 번째는 무시', () => {
    const c = cancel(rec())
    expect(c?.phase).toBe('cancelled')
    expect(cancel(c)).toBeUndefined()
    expect(submit(c, false)).toBeUndefined()
  })

  test('사람의 닫기: 숨김, 기록과 BUSY 유지', () => {
    const { record, showStatus } = personClose(rec())
    expect(record?.hidden).toBe(true)
    expect(showStatus).toBe(true)
    expect(decideCall(record, undefined)).toEqual({ kind: 'busy', id: 'f-00000001' })
  })

  test('사람이 영수증을 닫으면 버린다', () => {
    expect(personClose(submit(rec(), false)).record).toBeUndefined()
  })

  test('/question-form: 숨긴 질문지를 다시 보이고, 없으면 undefined', () => {
    expect(reopen(personClose(rec()).record)?.hidden).toBe(false)
    expect(reopen(undefined)).toBeUndefined()
    expect(reopen(submit(rec(), false))).toBeUndefined()
  })

  test('영수증은 묶음 턴의 turn.complete 에서 닫힌다', () => {
    const idle = turnComplete(submit(rec(), false))
    expect(idle.closeReceipt).toBe(true)
    expect(idle.record).toBeUndefined()
    // 사람의 턴이 도는 중에 제출하면 그 턴의 turn.complete 는 지나간다.
    const first = turnComplete(submit(rec(), true))
    expect(first.closeReceipt).toBe(false)
    expect(first.record?.phase).toBe('submitted')
    const second = turnComplete(first.record)
    expect(second.closeReceipt).toBe(true)
  })

  test('열린 질문지는 turn.complete 에 닫히지 않는다', () => {
    const r = rec()
    expect(turnComplete(r)).toEqual({ record: r, closeReceipt: false })
  })

  test('replaces 의 답 이어 받기: id·종류·라벨 집합이 같을 때만', () => {
    const drafts = {
      a: { selected: ['x'], other: '', note: '' },
      b: { selected: ['p'], other: '', note: '' },
      c: { selected: [], other: '글', note: '' },
    }
    const next: FormInput = {
      title: '새',
      questions: [
        { id: 'a', header: '가', question: '바뀐 문장', kind: 'single', options: [opt('y'), opt('x')] },
        { id: 'b', header: '나', question: '?', kind: 'multi', options: [opt('p'), opt('r')] },
        { id: 'c', header: '다', question: '?', kind: 'single', options: [opt('x'), opt('y')] },
      ],
    }
    expect(carryDrafts(form, drafts, next)).toEqual({ a: drafts.a })
  })

  test('보관: 같은 세션의 열린 기록만 되살리고 7일 넘으면 만료', () => {
    expect(restorable(rec(), 'sid')?.id).toBe('f-00000001')
    expect(restorable(rec(), 'other')).toBeUndefined()
    expect(restorable(submit(rec(), false), 'sid')).toBeUndefined()
    expect(expired(rec(), 1000 + STORE_TTL_MS)).toBe(false)
    expect(expired(rec(), 1001 + STORE_TTL_MS)).toBe(true)
    expect(restorable(rec(), 'sid', 1000 + STORE_TTL_MS)?.id).toBe('f-00000001')
    expect(restorable(rec(), 'sid', 1001 + STORE_TTL_MS)).toBeUndefined()
  })
})
