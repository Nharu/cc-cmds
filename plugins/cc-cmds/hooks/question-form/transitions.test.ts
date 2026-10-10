import { describe, expect, test } from 'claude-code/testing'

import {
  STORE_TTL_MS,
  advance,
  cancel,
  carryDrafts,
  choose,
  closeEditor,
  commitText,
  decideCall,
  expired,
  jump,
  openEditor,
  openRecord,
  personClose,
  placed,
  reopen,
  restorable,
  retreat,
  settleCursor,
  submit,
  typeText,
} from './transitions'
import type { FormRecord } from './transitions'
import type { FormInput } from './spec'

const opt = (label: string) => ({ label, description: '' })
const form: FormInput = {
  title: '시험',
  questions: [
    { id: 'a', header: '가', question: '?', kind: 'single', options: [opt('x'), opt('y')] },
    { id: 'b', header: '나', question: '?', kind: 'multi', options: [opt('p'), opt('q')] },
    { id: 'c', header: '다', question: '?', kind: 'text' },
    { id: 'd', header: '라', question: '?', kind: 'text', when: { id: 'a', selected: ['y'] } },
  ],
}
const rec = () => openRecord({ id: 'f-00000001', toolUseId: 'tu1', form, drafts: {}, sessionId: 'sid', now: 1000 })

describe('수명 주기', () => {
  test('열린 질문지: replaces 없으면 BUSY, 같은 id 면 갈아 끼우기, 없으면 새로', () => {
    expect(decideCall(undefined, undefined)).toEqual({ kind: 'new' })
    expect(decideCall(rec(), undefined)).toEqual({ kind: 'busy', id: 'f-00000001' })
    expect(decideCall(rec(), 'f-00000001')).toEqual({ kind: 'replace' })
    // 제출·취소된 기록은 묶음을 낸 자리에서 버려지므로 남아 있어도 BUSY 가 아니다.
    expect(decideCall(submit(rec()), undefined)).toEqual({ kind: 'new' })
  })

  test('열면 커서는 첫 질문, 입력칸은 없다', () => {
    const r = rec()
    expect(r.cursor).toBe('a')
    expect(r.editor).toBeNull()
  })

  test('미배치면 숨김으로 시작한다', () => {
    expect(placed(rec(), false).hidden).toBe(true)
    expect(placed(rec(), true).hidden).toBe(false)
  })

  test('[제출] CAS: open→submitted, 두 번째는 무시', () => {
    const s = submit(rec())
    expect(s?.phase).toBe('submitted')
    expect(submit(s)).toBeUndefined()
    expect(cancel(s)).toBeUndefined()
  })

  test('[답 없이 닫기] CAS: open→cancelled, 두 번째는 무시', () => {
    const c = cancel(rec())
    expect(c?.phase).toBe('cancelled')
    expect(cancel(c)).toBeUndefined()
    expect(submit(c)).toBeUndefined()
  })

  test('사람의 닫기: 숨김, 기록과 BUSY 유지', () => {
    const { record, showStatus } = personClose(rec())
    expect(record?.hidden).toBe(true)
    expect(showStatus).toBe(true)
    expect(decideCall(record, undefined)).toEqual({ kind: 'busy', id: 'f-00000001' })
  })

  test('/question-form: 숨긴 질문지를 다시 보이고, 없으면 undefined', () => {
    expect(reopen(personClose(rec()).record)?.hidden).toBe(false)
    expect(reopen(undefined)).toBeUndefined()
    expect(reopen(submit(rec()))).toBeUndefined()
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
    expect(restorable(submit(rec()), 'sid')).toBeUndefined()
    expect(expired(rec(), 1000 + STORE_TTL_MS)).toBe(false)
    expect(expired(rec(), 1001 + STORE_TTL_MS)).toBe(true)
    expect(restorable(rec(), 'sid', 1000 + STORE_TTL_MS)?.id).toBe('f-00000001')
    expect(restorable(rec(), 'sid', 1001 + STORE_TTL_MS)).toBeUndefined()
  })

  test('보관: 모델 입력에 엔진이 거부하는 제어 문자가 든 기록은 되살리지 않는다', () => {
    const r = rec()
    const withEsc = (patch: (f: FormInput) => void) => {
      const f: FormInput = JSON.parse(JSON.stringify(r.form))
      patch(f)
      return { ...r, form: f }
    }
    expect(restorable(withEsc(f => (f.questions[0]!.header = '가\u001b')), 'sid')).toBeUndefined()
    expect(restorable(withEsc(f => (f.title = '제\u0000목')), 'sid')).toBeUndefined()
    expect(restorable(withEsc(f => (f.questions[0]!.options![0]!.description = '설\u009b명')), 'sid')).toBeUndefined()
    // 한 줄 칸의 줄바꿈·탭은 엔진이 그리므로 되살린다.
    expect(restorable(withEsc(f => (f.questions[0]!.header = '가\t나')), 'sid')?.id).toBe('f-00000001')
    expect(restorable(withEsc(f => (f.intro = '첫\n둘')), 'sid')?.id).toBe('f-00000001')
  })

  test('앞 판이 보관한 기록(커서·입력칸 없음)은 첫 질문에서 되살린다', () => {
    const { cursor: _c, editor: _e, editorGen: _g, ...old } = rec()
    const stored = { ...old, otherOpen: [], receiptTurns: 0 } as unknown as FormRecord
    const alive = restorable(stored, 'sid')
    expect(alive?.cursor).toBe('a')
    expect(alive?.editor).toBeNull()
    expect(alive?.editorGen).toBe(0)
  })
})

describe('커서와 선택', () => {
  test('single 을 고르면 기타를 비우고 다음 질문으로, 다시 누르면 풀리고 그 자리', () => {
    const typed = typeText(rec(), 'a', 'other', '셋째')
    const picked = choose(typed, 'a', 'x')
    expect(picked.move).toBe('next')
    expect(picked.record.cursor).toBe('b')
    expect(picked.record.drafts.a).toEqual({ selected: ['x'], other: '', note: '' })
    const back = jump(picked.record, 'a')
    const undone = choose(back, 'a', 'x')
    expect(undone.move).toBe('stay')
    expect(undone.record.cursor).toBe('a')
    expect(undone.record.drafts.a?.selected).toEqual([])
  })

  test('multi 는 켜고 끄며 그 자리에 남는다', () => {
    const r = jump(rec(), 'b')
    const on = choose(r, 'b', 'p')
    expect(on.move).toBe('stay')
    expect(on.record.drafts.b?.selected).toEqual(['p'])
    const both = choose(on.record, 'b', 'q')
    expect(both.record.drafts.b?.selected).toEqual(['p', 'q'])
    const off = choose(both.record, 'b', 'p')
    expect(off.record.drafts.b?.selected).toEqual(['q'])
    expect(off.record.cursor).toBe('b')
  })

  test('마지막 질문에서 single 을 고르면 end — 포커스는 [제출]로', () => {
    const last: FormInput = { title: '한 문항', questions: [form.questions[0] as FormInput['questions'][number]] }
    const r = openRecord({ id: 'f-00000002', toolUseId: 'tu', form: last, drafts: {}, sessionId: 'sid', now: 0 })
    const picked = choose(r, 'a', 'x')
    expect(picked.move).toBe('end')
    expect(picked.record.cursor).toBe('a')
  })

  test('when 질문은 앞 답이 맞을 때만 커서가 닿고, 답이 바뀌어 사라지면 앞 질문으로 돌아온다', () => {
    const r = rec()
    expect(advance(jump(r, 'c'))).toBeUndefined()
    const shown = choose(r, 'a', 'y').record
    const onD = jump(shown, 'd')
    expect(onD.cursor).toBe('d')
    // text 질문에 답이 없으므로 답 칸이 열려 있다.
    expect(onD.editor).toMatchObject({ id: 'd', field: 'other', seed: '' })
    const hidden = choose(jump(onD, 'a'), 'a', 'x').record
    expect(settleCursor({ ...hidden, cursor: 'd' }).cursor).toBe('c')
  })

  test('다음·이전은 보이는 질문만 밟고 끝에서는 undefined', () => {
    const r = rec()
    expect(advance(r)?.cursor).toBe('b')
    expect(advance(advance(r) as FormRecord)?.cursor).toBe('c')
    expect(advance(jump(r, 'c'))).toBeUndefined()
    expect(retreat(r)).toBeUndefined()
    expect(retreat(jump(r, 'c'))?.cursor).toBe('b')
  })

  test('text 질문에 커서가 닿으면 답 칸이 열리고, 답이 있으면 답 줄만 보인다', () => {
    const empty = jump(rec(), 'c')
    expect(empty.editor).toMatchObject({ id: 'c', field: 'other', gen: 1, seed: '' })
    const answered = jump(typeText(rec(), 'c', 'other', '이유'), 'c')
    expect(answered.editor).toBeNull()
  })
})

describe('입력칸', () => {
  test('열 때마다 세대가 오르고(닫아도 되돌지 않는다) 그때의 답이 씨앗이다', () => {
    const r = rec()
    const first = openEditor(r, 'a', 'other')
    expect(first.editor).toEqual({ id: 'a', field: 'other', gen: 1, seed: '' })
    const typed = typeText(first, 'a', 'other', '중간')
    expect(typed.editor?.seed).toBe('')
    const closed = commitText(typed, 'a', 'other', '중간')
    expect(closed.record.editor).toBeNull()
    const again = openEditor(jump(closed.record, 'a'), 'a', 'other')
    expect(again.editor).toEqual({ id: 'a', field: 'other', gen: 2, seed: '중간' })
    const note = openEditor(closeEditor(again), 'a', 'note')
    expect(note.editor?.gen).toBe(3)
    expect(note.editorGen).toBe(3)
  })

  test('치는 동안 답이 바로 적히고, single 의 기타 글은 고른 선택지를 푼다', () => {
    const picked = choose(rec(), 'a', 'x').record
    const typed = typeText(picked, 'a', 'other', '셋')
    expect(typed.drafts.a).toEqual({ selected: [], other: '셋', note: '' })
    expect(typeText(typed, 'a', 'other', '').drafts.a?.other).toBe('')
  })

  test('확정: single 의 기타와 text 의 답은 다음으로, 메모와 multi 의 기타는 그 자리', () => {
    const r = rec()
    expect(commitText(openEditor(r, 'a', 'other'), 'a', 'other', '셋').move).toBe('next')
    expect(commitText(openEditor(r, 'a', 'other'), 'a', 'other', '  ').move).toBe('stay')
    expect(commitText(openEditor(r, 'a', 'note'), 'a', 'note', '참고').move).toBe('stay')
    const onB = jump(r, 'b')
    expect(commitText(openEditor(onB, 'b', 'other'), 'b', 'other', '라').move).toBe('stay')
    const onC = jump(r, 'c')
    const done = commitText(onC, 'c', 'other', '이유')
    expect(done.move).toBe('end')
    expect(done.record.drafts.c?.other).toBe('이유')
    expect(done.record.editor).toBeNull()
  })

  test('친 글은 제어 문자를 거른 값으로 초안에 적힌다', () => {
    const typed = typeText(openEditor(rec(), 'a', 'other'), 'a', 'other', '앱으로\n가는데\u001b')
    expect(typed.drafts.a?.other).toBe('앱으로 가는데')
    const note = typeText(openEditor(rec(), 'a', 'note'), 'a', 'note', '참\t고\u0000')
    expect(note.drafts.a?.note).toBe('참 고')
  })

  test('제어 문자만 친 기타·답을 확정하면 다음 질문으로 넘어가지 않는다', () => {
    const r = rec()
    const single = commitText(openEditor(r, 'a', 'other'), 'a', 'other', '\u001b\u0000')
    expect(single.move).toBe('stay')
    expect(single.record.cursor).toBe('a')
    const text = commitText(jump(r, 'c'), 'c', 'other', '\u007f')
    expect(text.move).toBe('stay')
  })

  test('제어 문자만 든 text 초안에 커서가 닿으면 답 칸을 연다', () => {
    const r = { ...rec(), drafts: { c: { selected: [], other: '\u001b\u0000', note: '' } } }
    expect(jump(r, 'c').editor).toMatchObject({ id: 'c', field: 'other' })
  })

  test('그 질문의 single 선택지를 고르면 열린 기타 칸이 닫힌다', () => {
    const open = openEditor(rec(), 'a', 'other')
    expect(choose(open, 'a', 'x').record.editor).toBeNull()
    const note = openEditor(rec(), 'a', 'note')
    expect(choose(note, 'a', 'x').record.editor).toBeNull()
  })
})
