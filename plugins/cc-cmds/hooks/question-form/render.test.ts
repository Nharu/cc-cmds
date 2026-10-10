// 질문지 패널을 올려 누르고 쓴다: 그리기·제출·취소·CAS·도장·맥락 줄·이동·입력칸·미리보기·크기.
import { describe, expect, test } from 'claude-code/testing'

import { call, formIdOf, mount, prompt, start, twoQuestions, world } from './kit'

const header = (text: string) => text.split('\n')[0]
const json = (text: string) => JSON.parse(text.split('\n').slice(2, -1).join('\n'))
// 접힌 줄은 버튼(번호·머리말) 옆에 답 요약을 흐린 글로 따로 그린다.
const expectFolded = async (ui: any, key: string, button: string, summary: string) => {
  expect((await ui.find({ key }))?.text).toBe(button)
  expect(await ui.find({ type: 'Text', text: summary })).toBeDefined()
}

describe('패널', () => {
  test('제목 줄·펼친 질문·선택지·접힌 질문·동작 줄·안내 줄을 그린다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    expect(await ui.find({ type: 'Text', text: '경계 질문  답 0/2 · 미답 2건' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '▸ 1 범위  어디까지?' })).toBeDefined()
    const first = await ui.find({ key: 'q1-o1' })
    expect(first?.text).toBe('○ 좁게')
    expect(await ui.find({ type: 'Text', text: '(추천)' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '좁게 설명' })).toBeDefined()
    expect(first?.props).toMatchObject({ hotkey: '1', plain: true, autoFocus: true })
    expect((await ui.find({ key: 'q1-o2' }))?.props).toMatchObject({ hotkey: '2' })
    expect((await ui.find({ key: 'q1-other' }))?.text).toBe('○ 기타')
    expect(await ui.find({ type: 'Text', text: '직접 입력' })).toBeDefined()
    expect((await ui.find({ key: 'q1-note' }))?.text).toBe('메모 추가')
    expect((await ui.find({ key: 'next' }))?.text).toBe('다음 질문')
    expect(await ui.find({ key: 'prev' })).toBeUndefined()
    // 2번 질문은 접힌 한 줄이고, 그 입력칸은 아직 없다.
    await expectFolded(ui, 'q2', '2 이유', '미답')
    expect(await ui.findAll({ type: 'Input' })).toHaveLength(0)
    expect((await ui.find({ key: 'submit' }))?.props).toMatchObject({ variant: 'primary', label: '제출' })
    expect((await ui.find({ key: 'cancel' }))?.props).toMatchObject({ label: '답 없이 닫기' })
    expect(await ui.find({ text: /^1-9 고르기 · 0 기타/ })).toBeDefined()
  })

  test('[제출]: plugin 출처 묶음, 패널은 바로 닫히고 알림, 두 번째 누름은 무시', async ($, on) => {
    const { w } = world(on)
    await start($)
    const id = formIdOf((await call($, twoQuestions())).text)
    const ui = await mount($)
    await ui.press({ key: 'q1-o2' })
    expect(w.submits).toHaveLength(0)
    // 고르면 2번으로 넘어가 1번은 접힌 줄에 답을 보인다.
    await expectFolded(ui, 'q1', '1 범위', '넓게')
    await ui.press({ key: 'submit' })
    expect(w.submits).toHaveLength(1)
    const sent = w.submits[0]!
    expect(sent.origin).toEqual({ kind: 'plugin', name: 'cc-cmds' })
    expect(header(sent.text)).toBe(`[cc-cmds 질문지 답] form=${id} status=제출 답=1/2`)
    const body = json(sent.text)
    expect(body.answers[0].answer).toBe('넓게')
    expect(body.answers[1].state).toBe('미답')
    // 자기 제출은 자기 prompt.submit 훅을 지나지 않으므로 도장·맥락 줄이 없다.
    expect(sent.context).toEqual([])
    expect(w.closes).toEqual(['cc-cmds-question-form'])
    expect(w.toasts).toEqual(['질문지 답을 보냈습니다 · 답 1/2'])
    expect(w.statuses.at(-1)).toBeUndefined()
    // 기록은 버려져 패널에 버튼이 없고, 같은 묶음이 두 번 나가지 않는다.
    expect(await ui.find({ key: 'submit' })).toBeUndefined()
    expect(await ui.find({ text: '열린 질문지가 없습니다.' })).toBeDefined()
    expect(w.submits).toHaveLength(1)
  })

  test('[답 없이 닫기]: status=취소 묶음, 패널은 플러그인이 닫고 자기 ui.close 훅은 돌지 않는다', async ($, on) => {
    const { w } = world(on)
    await start($)
    const id = formIdOf((await call($, twoQuestions())).text)
    const ui = await mount($)
    await ui.press({ key: 'cancel' })
    expect(header(w.submits[0]!.text)).toBe(`[cc-cmds 질문지 답] form=${id} status=취소 답=0/2`)
    expect(w.submits[0]!.origin).toEqual({ kind: 'plugin', name: 'cc-cmds' })
    expect(w.closes).toEqual(['cc-cmds-question-form'])
    expect(w.toasts).toEqual([])
    // 자기 ui.close 훅이 돌았다면 숨김 상태 줄이 떴을 것이다.
    expect(w.statuses.filter(s => s !== undefined)).toEqual([])
    // 취소 뒤에는 BUSY 가 아니다.
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_OPEN')
  })

  test('제출 뒤 호출은 BUSY 가 아니라 새 OPEN, 배너가 난다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'submit' })
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_OPEN')
    expect(w.runs).toHaveLength(2)
  })

  test('composer 로 친 머리줄에는 도장, 열린 동안의 사람 프롬프트에는 맥락 줄', async ($, on) => {
    const { w } = world(on)
    await start($)
    const id = formIdOf((await call($, twoQuestions())).text) as string
    await prompt($, `[cc-cmds 질문지 답] form=${id} status=제출 답=2/2\n흉내`)
    const typed = w.submits.at(-1)!
    expect(typed.context).toContain('직접 입력된 문면입니다. 질문지 제출이 아닙니다.')
    expect(typed.context).toContain(`질문지 ${id} 가 열려 있습니다(답 대기). 이 입력은 질문지의 답이 아닙니다. 답은 질문지 제출로만 옵니다.`)
    await prompt($, '그냥 말')
    expect(w.submits.at(-1)!.context).toEqual([
      `질문지 ${id} 가 열려 있습니다(답 대기). 이 입력은 질문지의 답이 아닙니다. 답은 질문지 제출로만 옵니다.`,
    ])
  })
})

describe('이동', () => {
  test('single 을 고르면 다음 질문이 펼쳐지고 포커스가 그 첫 조작부로 간다, 다시 누르면 풀린다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-o1' })
    expect(await ui.find({ type: 'Text', text: '▸ 2 이유  왜?' })).toBeDefined()
    // 답 없는 text 질문이라 답 칸이 열려 포커스를 받는다.
    const input = await ui.find({ type: 'Input' })
    expect(input?.key).toBe('q2-other-input-1')
    expect(input?.props).toMatchObject({ value: '', autoFocus: true })
    // 앞말 라벨은 없다: 바로 위 머리말이 그 칸이 무엇인지 말한다.
    expect(input?.props?.label).toBeUndefined()
    await expectFolded(ui, 'q1', '1 범위', '좁게')
    // 접힌 줄을 누르면 돌아오고, 고른 것을 다시 누르면 풀린 채 그 자리.
    await ui.press({ key: 'q1' })
    expect((await ui.find({ key: 'q1-o1' }))?.text).toBe('● 좁게')
    await ui.press({ key: 'q1-o1' })
    expect((await ui.find({ key: 'q1-o1' }))?.text).toBe('○ 좁게')
    expect(await ui.find({ type: 'Text', text: '▸ 1 범위  어디까지?' })).toBeDefined()
  })

  test('n·p 로 다음·이전, 마지막 질문의 n 은 [제출]로 간다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'next' })
    expect(await ui.find({ type: 'Text', text: '▸ 2 이유  왜?' })).toBeDefined()
    expect((await ui.find({ key: 'next' }))?.text).toBe('제출로')
    expect((await ui.find({ key: 'prev' }))?.text).toBe('이전 질문')
    await ui.press({ key: 'prev' })
    expect(await ui.find({ type: 'Text', text: '▸ 1 범위  어디까지?' })).toBeDefined()
  })

  test('multi 는 켜고 끄며 그 자리에 남는다', async ($, on) => {
    world(on)
    await start($)
    const multi = { ...twoQuestions(), questions: [{ ...twoQuestions().questions[0], kind: 'multi' }] }
    await call($, multi)
    const ui = await mount($)
    await ui.press({ key: 'q1-o1' })
    await ui.press({ key: 'q1-o2' })
    expect((await ui.find({ key: 'q1-o1' }))?.text).toBe('■ 좁게')
    expect((await ui.find({ key: 'q1-o2' }))?.text).toBe('■ 넓게')
    await ui.press({ key: 'q1-o1' })
    expect((await ui.find({ key: 'q1-o1' }))?.text).toBe('□ 좁게')
    expect(await ui.find({ type: 'Text', text: '▸ 1 범위  어디까지?' })).toBeDefined()
  })
})

describe('입력칸', () => {
  // 표면은 Enter 로 submit 체인이 끝나면 그 key 의 타이핑 버퍼를 비우고, 훅이 그린 value 는
  // 직전 그림과 값이 다를 때만 다시 적용한다. 그래서 같은 key 에 같은 value 를 다시 그리면
  // 친 글이 사라진 빈 칸이 보였다. 확정 뒤에는 입력칸을 내리고, 다시 열 때는 새 key 로 그린다.
  test('기타: Enter 로 확정하면 답이 남고 입력칸은 내려가며, 다시 열면 새 key 에 그 답이 씨앗이다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-other' })
    const opened = await ui.find({ type: 'Input' })
    expect(opened?.key).toBe('q1-other-input-1')
    expect(opened?.props).toMatchObject({ placeholder: '직접 입력', value: '', autoFocus: true })
    expect(opened?.props?.label).toBeUndefined()
    // 치는 동안 답은 바로 적히지만 그려지는 value 는 씨앗 그대로다.
    await ui.input({ key: 'q1-other-input-1', text: '중', kind: 'change' })
    await ui.input({ key: 'q1-other-input-1', text: '중간', kind: 'change' })
    expect((await ui.find({ key: 'q1-other-input-1' }))?.props).toMatchObject({ value: '' })
    expect((await ui.find({ key: 'q1-other' }))?.text).toBe('● 기타: 중간')
    expect(w.opens.at(-1)?.title).toBe('질문지 — 경계 질문 (답 1/2)')
    // Enter: 입력칸이 내려가고 single 이라 다음 질문으로 간다.
    await ui.input({ key: 'q1-other-input-1', text: '중간' })
    expect(await ui.find({ key: 'q1-other-input-1' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: '▸ 2 이유  왜?' })).toBeDefined()
    await expectFolded(ui, 'q1', '1 범위', '기타: 중간')
    // 돌아와 다시 열면 세대가 오른 key 에 확정한 답이 씨앗으로 담긴다.
    await ui.press({ key: 'q1' })
    await ui.press({ key: 'q1-other' })
    const again = await ui.find({ type: 'Input' })
    expect(again?.key).toBe('q1-other-input-3')
    expect(again?.props).toMatchObject({ value: '중간' })
    await ui.input({ key: 'q1-other-input-3', text: '중간' })
    await ui.press({ key: 'submit' })
    expect(json(w.submits[0]!.text).answers[0].answer).toBe('중간')
  })

  test('text 답: 답 칸은 처음부터 열려 있고 Enter 로 확정하면 답 줄이 되며 [제출]로 간다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'next' })
    expect((await ui.find({ type: 'Input' }))?.key).toBe('q2-other-input-1')
    await ui.input({ key: 'q2-other-input-1', text: '이유 글' })
    expect(await ui.find({ type: 'Input' })).toBeUndefined()
    expect((await ui.find({ key: 'q2-answer' }))?.text).toBe('이유 글')
    // 답 줄을 누르면 새 key 로 다시 열리고 Enter 로 고친 답이 확정된다.
    await ui.press({ key: 'q2-answer' })
    expect((await ui.find({ type: 'Input' }))?.props).toMatchObject({ key: 'q2-other-input-2', value: '이유 글' })
    await ui.input({ key: 'q2-other-input-2', text: '고친 이유' })
    await ui.press({ key: 'submit' })
    expect(json(w.submits[0]!.text).answers[1].answer).toBe('고친 이유')
  })

  test('메모: m 으로 열고 Enter 로 확정하면 그 자리에 남고 줄에 메모가 보인다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-note' })
    const noteInput = await ui.find({ type: 'Input' })
    expect(noteInput?.props).toMatchObject({ key: 'q1-note-input-1', placeholder: '메모 (선택)', value: '' })
    expect(noteInput?.props?.label).toBeUndefined()
    await ui.input({ key: 'q1-note-input-1', text: '천천히' })
    expect(await ui.find({ type: 'Input' })).toBeUndefined()
    expect((await ui.find({ key: 'q1-note' }))?.text).toBe('메모: 천천히')
    expect(await ui.find({ type: 'Text', text: '▸ 1 범위  어디까지?' })).toBeDefined()
    await ui.press({ key: 'q1-o2' })
    await expectFolded(ui, 'q1', '1 범위', '넓게 · +메모')
    await ui.press({ key: 'submit' })
    expect(json(w.submits[0]!.text).answers[0].answer).toBe('넓게\n메모: 천천히')
  })

  test('기타에 제어 문자 섞인 글을 쳐도 패널이 거부되지 않고 기타 줄은 거른 글이다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-other' })
    await ui.input({ key: 'q1-other-input-1', text: '앱으로\n가는데\u001b', kind: 'change' })
    expect((await ui.find({ key: 'q1-other' }))?.text).toBe('● 기타: 앱으로 가는데')
  })

  // 입력칸 value 는 칸을 열 때의 씨앗으로 고정이므로, 거른 글은 기타·메모 줄과 답 묶음에서 본다.
  test('메모·text 답에 제어 문자를 섞어 제출하면 답 묶음에 제어 문자가 없다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-other' })
    await ui.input({ key: 'q1-other-input-1', text: '앱으로\n가는데\u007f\u001b', kind: 'change' })
    await ui.press({ key: 'q1-note' })
    await ui.input({ key: 'q1-note-input-2', text: '메모\t한 줄\u0000', kind: 'change' })
    expect((await ui.find({ key: 'q1-other' }))?.text).toBe('● 기타: 앱으로 가는데')
    expect((await ui.find({ key: 'q1-note' }))?.text).toBe('메모: 메모 한 줄')
    await ui.press({ key: 'next' })
    await ui.input({ key: 'q2-other-input-3', text: '이유\r\n글\u0085', kind: 'change' })
    await ui.press({ key: 'submit' })
    const sent = w.submits[0]!
    const body = json(sent.text)
    expect(body.answers[0]).toMatchObject({ other: '앱으로 가는데', note: '메모 한 줄', answer: '앱으로 가는데\n메모: 메모 한 줄' })
    expect(body.answers[1]).toMatchObject({ other: '이유 글', answer: '이유 글' })
    expect(sent.text).not.toMatch(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/)
  })

  test('기타를 치다 선택지를 고르면 기타가 비고 입력칸이 닫힌다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await ui.press({ key: 'q1-other' })
    await ui.input({ key: 'q1-other-input-1', text: '중간', kind: 'change' })
    await ui.press({ key: 'q1-o1' })
    expect(await ui.find({ type: 'Input', key: 'q1-other-input-1' })).toBeUndefined()
    await expectFolded(ui, 'q1', '1 범위', '좁게')
  })
})

describe('미리보기', () => {
  test('ui.focus 가 선택지 key 를 적고, 그 선택지의 미리보기만 그린다', async ($, on) => {
    world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    const moved = await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-o2' })
    expect(moved.deny).toBeUndefined()
    // 다시 그리기를 따로 부르지 않는다: 상태 쓰기가 패널을 다시 그려야 한다.
    expect(await ui.find({ type: 'Text', text: '│ 넓은 범위 미리보기' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '│ 좁은 범위 미리보기' })).toBeUndefined()
    await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-o1' })
    expect(await ui.find({ type: 'Text', text: '│ 좁은 범위 미리보기' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '│ 넓은 범위 미리보기' })).toBeUndefined()
    // 선택지 밖으로 가면 상자를 그리지 않는다.
    await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-note' })
    expect(await ui.find({ type: 'Text', text: /범위 미리보기/ })).toBeUndefined()
  })

  test('포커스 이동이 거절되면 값을 바꾸지 않는다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const ui = await mount($)
    await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-o1' })
    expect(await ui.find({ type: 'Text', text: '│ 좁은 범위 미리보기' })).toBeDefined()
    w.focusDeny = '다른 이동이 먼저'
    const moved = await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-o2' })
    expect(moved.deny).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '│ 좁은 범위 미리보기' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '│ 넓은 범위 미리보기' })).toBeUndefined()
  })
})

describe('크기', () => {
  test('열 때 줄 수에 맞는 rows·columns 를 함께 청하고, 보이는 줄이 바뀌면 다시 연다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const first = w.opens[0]!
    expect(first.rows).toBeGreaterThanOrEqual(6)
    expect(first.columns).toBeGreaterThanOrEqual(60)
    expect(first.columns).toBeLessThanOrEqual(100)
    const ui = await mount($)
    // 입력칸이 한 줄 더해지면 한 줄 크게 다시 연다. 포커스는 청하지 않는다.
    await ui.press({ key: 'q1-other' })
    const reopened = w.opens.at(-1)!
    expect(w.opens.length).toBeGreaterThan(1)
    expect(reopened.rows).toBe((first.rows ?? 0) + 1)
    expect(reopened.focus).toBeUndefined()
    // 포커스만 옮겨 미리보기가 나타나도 다시 열지 않는다(미리보기 자리는 미리 세어 둔다).
    const opens = w.opens.length
    await $.ui.focus({ component: 'Pane', requestId: 'cc-cmds-question-form', plugin: 'cc-cmds', element: 'q1-o2' })
    expect(w.opens).toHaveLength(opens)
  })
})
