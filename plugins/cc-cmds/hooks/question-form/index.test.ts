// 질문지 서브 mod 의 등록 술어·가용성 순서·BUSY·갈아 끼우기·/clear·되돌리기·배너·미배치.
import { describe, expect, test } from 'claude-code/testing'

import { MARKS, call, formIdOf, prompt, reopenCommand, start, twoQuestions, world } from './kit'

describe('등록 술어', () => {
  test('대화형이고 표지가 없으면 도구와 /question-form 을 등록한다', async ($, on) => {
    const { w } = world(on)
    await start($)
    expect(w.tools).toEqual(['question_form'])
    expect(w.commands).toContain('question-form')
  })

  test('비대화형이면 등록하지 않는다', async ($, on) => {
    const { w } = world(on)
    await start($, false)
    expect(w.tools).toHaveLength(0)
  })

  for (const mark of MARKS) {
    test(`표지 ${mark} 가 있으면 등록하지 않는다`, async ($, on) => {
      const { w } = world(on, { env: { [mark]: 'x' } })
      await start($)
      expect(w.tools).toHaveLength(0)
      expect(w.commands).not.toContain('question-form')
    })
  }

  test('빈 문자열 표지는 표지가 아니다', async ($, on) => {
    const { w } = world(on, { env: { CC_PIPELINE_SEGMENT: '', CC_PIPELINE_RUN_ID: '' } })
    await start($)
    expect(w.tools).toEqual(['question_form'])
  })

  test('런 패널도 SEGMENT 표지만으로 깨어나지 않는다', async ($, on) => {
    const { w } = world(on, { env: { CC_PIPELINE_SEGMENT: 'A' } })
    await start($)
    expect(w.commands).not.toContain('autopilot-status')
  })
})

describe('가용성 순서', () => {
  test('subagent 가 가장 먼저다', async ($, on) => {
    const { w } = world(on)
    await start($)
    w.surfaces = []
    const { text, isRefused } = await call($, twoQuestions(), { agentId: 'agent-1' })
    expect(isRefused).toBe(true)
    expect(text).toContain('QUESTION_FORM_UNAVAILABLE subagent')
  })

  test('등록 뒤 생긴 표지는 pipeline 이다', async ($, on) => {
    const { w } = world(on, { env: { CC_PIPELINE_STAGE_ID: 'A' } })
    // 표지가 있으면 등록되지 않지만 호출 경로의 두 번째 벽도 따로 본다.
    w.surfaces = []
    const { text } = await call($, twoQuestions())
    expect(text).toContain('QUESTION_FORM_UNAVAILABLE pipeline')
  })

  test("표면 ['vscode'] 와 [] 는 surface, ['terminal','mobile'] 은 OPEN", async ($, on) => {
    const { w } = world(on)
    await start($)
    w.surfaces = ['vscode']
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_UNAVAILABLE surface')
    w.surfaces = []
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_UNAVAILABLE surface')
    w.surfaces = ['terminal', 'mobile']
    expect((await call($, twoQuestions())).text).toMatch(/^QUESTION_FORM_OPEN f-[0-9a-f]{8} 질문 2건\n/)
  })

  test('bridge 프롬프트 뒤에는 remote', async ($, on) => {
    world(on)
    await start($)
    await prompt($, '휴대폰에서 보낸 말', { kind: 'bridge' })
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_UNAVAILABLE remote')
    await prompt($, '터미널에서 친 말', { kind: 'composer' })
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_OPEN')
  })

  test('입력이 틀리면 INVALID', async ($, on) => {
    world(on)
    await start($)
    const { text, isRefused } = await call($, { title: '', questions: [] })
    expect(isRefused).toBe(true)
    expect(text).toContain('QUESTION_FORM_INVALID title:')
  })
})

describe('열기와 BUSY', () => {
  test('OPEN 본문, 두 번째 호출은 BUSY, replaces 는 새 id 로 배너 없이', async ($, on) => {
    const { w } = world(on)
    await start($)
    const first = await call($, twoQuestions())
    expect(first.isRefused).toBe(false)
    const id = formIdOf(first.text)
    expect(id).toMatch(/^f-[0-9a-f]{8}$/)
    const lines = first.text.split('\n')
    expect(lines[1]).toContain('이 턴을 지금 끝내세요')
    expect(lines[2]).toContain(`[cc-cmds 질문지 답] form=${id}`)
    expect(lines).toHaveLength(3)
    expect(w.opens[0]).toMatchObject({ id: 'cc-cmds-question-form', title: '질문지 — 경계 질문 (답 0/2)', focus: true })
    expect(w.runs).toHaveLength(1)

    expect((await call($, twoQuestions())).text).toContain(`QUESTION_FORM_BUSY ${id}`)
    expect((await call($, { ...twoQuestions(), replaces: 'f-00000000' })).text).toContain('QUESTION_FORM_INVALID replaces:')

    const replaced = await call($, { ...twoQuestions(), title: '고친 질문', replaces: id })
    const id2 = formIdOf(replaced.text)
    expect(id2).toMatch(/^f-[0-9a-f]{8}$/)
    expect(id2).not.toBe(id)
    expect(w.runs).toHaveLength(1)
  })

  test('/clear 는 버리고, 그 뒤 새로 열면 배너가 난다', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    await $.session.end({ reason: 'clear', sessionId: 'sid-test', resume: {} as never })
    const again = await call($, twoQuestions())
    expect(again.text).toContain('QUESTION_FORM_OPEN')
    expect(w.runs).toHaveLength(2)
  })

  test('미배치면 덧붙임 줄과 상태 줄', async ($, on) => {
    const { w } = world(on)
    await start($)
    w.isPlaced = false
    const { text } = await call($, twoQuestions())
    expect(text.split('\n')[3]).toBe(
      '패널이 좁은 화면이라 아직 그려지지 않았습니다. 상태 줄의 /question-form 안내가 사람에게 보이므로 따로 알리지 말고 턴을 끝내세요.',
    )
    expect(w.statuses.at(-1)).toBe('질문지 대기 중 · 답 0/2 · /question-form 으로 열기')
  })

  test('/question-form: 열린 질문지를 다시 열고 상태 줄을 지운다, 없으면 알림', async ($, on) => {
    const { w } = world(on)
    await start($)
    await reopenCommand($)
    expect(w.toasts).toEqual(['열린 질문지가 없습니다.'])
    w.isPlaced = false
    await call($, twoQuestions())
    w.isPlaced = true
    await reopenCommand($)
    expect(w.opens).toHaveLength(2)
    expect(w.statuses.at(-1)).toBeUndefined()
  })
})

describe('되돌리기와 배너', () => {
  test('ui.open 이 실패하면 기록을 되돌리고 UNAVAILABLE error, 다음 호출은 OPEN', async ($, on) => {
    const { w } = world(on)
    await start($)
    w.openFails = true
    const failed = await call($, twoQuestions())
    expect(failed.isRefused).toBe(true)
    expect(failed.text).toContain('QUESTION_FORM_UNAVAILABLE error')
    w.openFails = false
    expect((await call($, twoQuestions())).text).toContain('QUESTION_FORM_OPEN')
  })

  test('배너(process.run)가 실패해도 기록은 남고 OPEN', async ($, on) => {
    const { w } = world(on)
    await start($)
    w.runFails = true
    const opened = await call($, twoQuestions())
    expect(opened.text).toContain('QUESTION_FORM_OPEN')
    const id = formIdOf(opened.text)
    expect((await call($, twoQuestions())).text).toContain(`QUESTION_FORM_BUSY ${id}`)
  })

  test('배너 인자: argv·env 키 집합·stdin 모양, agent_id 없음', async ($, on) => {
    const { w } = world(on)
    await start($)
    await call($, twoQuestions())
    const run = w.runs[0]
    expect(run.argv[0]).toBe('/bin/bash')
    expect(run.argv[1]).toMatch(/\/hooks\/session-ask-notify\.sh$/)
    expect(Object.keys(run.env ?? {})).toEqual(['CLAUDE_PLUGIN_ROOT'])
    expect(run.timeoutMs).toBe(5000)
    const stdin = JSON.parse(run.stdin ?? '{}')
    expect(stdin).toEqual({
      hook_event_name: 'PreToolUse',
      session_id: 'sid-test',
      tool_name: 'mcp__cc-cmds__question_form',
      tool_input: {
        questions: [
          { header: '범위', question: '어디까지?' },
          { header: '이유', question: '왜?' },
        ],
      },
    })
  })
})
