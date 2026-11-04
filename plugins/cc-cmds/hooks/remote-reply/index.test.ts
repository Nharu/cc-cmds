// 원격 답 모드의 활성 판정·열린 질문 경합·질문지 적용·깨우기·시계 복구·잠든 상태.
import { describe, expect, test } from 'claude-code/testing'

import { call, formIdOf, mount, twoQuestions } from '../question-form/kit'
import type { FormInput } from '../question-form/spec'
import { openRecord } from '../question-form/transitions'
import { normalizeForm } from '../question-form/validate'
import { CLEANUP_TICKS, IDLE_MS, SCAN_MS } from './index'
import { MARKS, OWN, QUESTIONS, ROOT, SID, STATE, ask, prompt, seamSubs, start, turnDone, turnStart, world } from './kit'

const REMOTE = { '어디까지?': '넓게' }
const LITERAL = '<cc-remote-approval run=run-1 id=a-0123abcd/>'
const WAKE = { run_id: 'run-1', approval_id: 'a-0123abcd', reply_id: 'r9' }

// 런 주소 봉투 하나가 놓인 정방향 색인과 우편함.
const runMailbox = (w: any) => {
  w.files[`${STATE}/session/${SID}`] = 'run-1\n'
  w.dirs[`${ROOT}/inbox/r-run-1`] = ['r9.json']
}

const scanOut = (form: unknown, wake: unknown[] = []) => JSON.stringify({ form, wake })

describe('활성 판정', () => {
  test('대화형이고 표지가 없으면 활성이 되어 정리부터 한다', async ($, on) => {
    const { w } = world(on)
    await start($)
    expect(seamSubs(w)).toEqual(['cleanup'])
    expect(JSON.parse(w.seams[0].stdin ?? '{}')).toEqual({ session_id: SID })
  })

  test('비대화형이면 스풀을 보지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.dirs[OWN] = ['r1.json']
    await start($, false)
    await clock.advance(SCAN_MS * 4)
    expect(w.lists).toBe(0)
    expect(w.seams).toHaveLength(0)
  })

  for (const mark of MARKS) {
    test(`표지 ${mark} 가 있으면 활성이 아니다`, async ($, on) => {
      const { w, clock } = world(on, { env: { [mark]: 'x' } })
      w.dirs[OWN] = ['r1.json']
      await start($)
      await clock.advance(SCAN_MS * 4)
      expect(w.lists).toBe(0)
      expect(w.seams).toHaveLength(0)
    })
  }

  test('HOME 이 없으면 활성이 아니다', async ($, on) => {
    const { w, clock } = world(on, { home: null })
    await start($)
    await clock.advance(SCAN_MS * 4)
    expect(w.lists).toBe(0)
    expect(w.seams).toHaveLength(0)
  })

  test('하위 에이전트의 질문에는 끼어들지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    const p = ask($, 'tu-1', { agentId: 'agent-1' })
    await clock.advance(5000)
    const r = await p
    expect(w.spawns).toHaveLength(0)
    expect(r.result.answers).toEqual(w.localAnswers)
  })
})

describe('잠든 상태', () => {
  test('스풀 루트가 없으면 프로세스를 하나도 띄우지 않는다', async ($, on) => {
    const { w, clock } = world(on, { spool: false })
    w.dirs[OWN] = ['r1.json']
    runMailbox(w)
    await start($)
    await clock.advance(SCAN_MS * 6)
    const p = ask($, 'tu-1')
    await clock.advance(5000)
    const r = await p
    expect(w.seams).toHaveLength(0)
    expect(w.spawns).toHaveLength(0)
    expect(r.result.answers).toEqual(w.localAnswers)
  })

  test('후보 봉투가 없으면 틱이 프로세스를 띄우지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    await clock.advance(SCAN_MS * 6)
    expect(seamSubs(w)).toEqual(['cleanup'])
  })

  test(`정리는 활성 직후와 ${CLEANUP_TICKS} 틱마다 한다`, async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    await clock.advance(SCAN_MS * CLEANUP_TICKS)
    expect(seamSubs(w)).toEqual(['cleanup', 'cleanup'])
  })
})

describe('열린 질문 경합', () => {
  test('원격이 먼저면 확정한 답 맵으로 답한다', async ($, on) => {
    const { w, clock } = world(on)
    w.waits = [`s-${SID} r1`]
    w.replies.commit = JSON.stringify(REMOTE)
    await start($)
    const p = ask($, 'tu-1')
    await clock.advance(1000)
    const r = await p
    expect(r.result).toEqual({ questions: QUESTIONS, answers: REMOTE })
    const commit = w.seams.find(c => c.sub === 'commit')
    expect(commit?.args).toEqual([`s-${SID}`, 'r1'])
    expect(JSON.parse(commit?.stdin ?? '{}')).toEqual({ session_id: SID, tool_use_id: 'tu-1', questions: QUESTIONS })
    expect(JSON.parse(w.spawns[0].input ?? '{}')).toEqual({ session_id: SID, tool_use_id: 'tu-1', questions: QUESTIONS, rejected: [] })
    expect(w.spawns[0].argv.slice(-1)).toEqual(['wait'])
  })

  test('로컬이 먼저면 로컬 결과를 그대로 두고 확정하지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.waits = [`s-${SID} r1`]
    w.waitDelayMs = 600_000
    w.replies.commit = JSON.stringify(REMOTE)
    await start($)
    const p = ask($, 'tu-1')
    await clock.advance(5000)
    const r = await p
    expect(r.result.answers).toEqual(w.localAnswers)
    await clock.advance(600_000)
    expect(seamSubs(w)).not.toContain('commit')
  })

  test('입력에 answers 가 이미 있으면 경합하지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    const p = ask($, 'tu-1', { answers: REMOTE })
    await clock.advance(5000)
    await p
    expect(w.spawns).toHaveLength(0)
  })

  test('확정이 거절되면 그 reply_id 를 빼고 다시 기다린다', async ($, on) => {
    const { w, clock } = world(on)
    w.waits = [`s-${SID} r1`, `s-${SID} r2`]
    w.replies.commit = ['', JSON.stringify(REMOTE)]
    await start($)
    const p = ask($, 'tu-1')
    await clock.advance(1000)
    await clock.advance(1000)
    const r = await p
    expect(r.result.answers).toEqual(REMOTE)
    expect(w.spawns).toHaveLength(2)
    expect(JSON.parse(w.spawns[1].input ?? '{}').rejected).toEqual(['r1'])
    expect(w.seams.filter(c => c.sub === 'commit').map(c => c.args[1])).toEqual(['r1', 'r2'])
  })

  test('대기 자식이 뜨지 못하면 로컬 결과만 기다린다', async ($, on) => {
    const { w, clock } = world(on)
    w.isSpawnFailing = true
    await start($)
    const p = ask($, 'tu-1')
    await clock.advance(5000)
    const r = await p
    expect(r.result.answers).toEqual(w.localAnswers)
    expect(seamSubs(w)).not.toContain('commit')
  })
})

describe('질문지 적용', () => {
  const openForm = async ($: any) => formIdOf((await call($, twoQuestions())).text) ?? ''

  test('초안이 없으면 수령하고 한 번의 갱신으로 고르고 제출한 뒤 그 텍스트로 기록한다', async ($, on) => {
    const { w, clock } = world(on)
    const writes: unknown[] = []
    on('state.set', { plugin: 'cc-cmds', key: 'questionForm.record' }, (_$: any, e: any, next: any) => {
      writes.push(e.value)

      return next(e)
    })
    await start($)
    const formId = await openForm($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut({ reply_id: 'r1', picks: [{ id: 'scope', label: '넓게' }] })
    w.replies['form-pick'] = 'r1\n'
    const before = writes.length
    await clock.advance(SCAN_MS)
    expect(seamSubs(w)).toEqual(['cleanup', 'scan', 'form-pick', 'form-record'])
    const scan = JSON.parse(w.seams[1].stdin ?? '{}')
    expect(scan.session_id).toBe(SID)
    expect(scan.form.form_id).toBe(formId)
    expect(scan.form.questions[0]).toEqual({ id: 'scope', question: '어디까지?', options: [{ label: '좁게' }, { label: '넓게' }] })
    expect(w.seams[2].args).toEqual(['r1'])
    const record = w.seams[3]
    expect(record.args).toEqual([SID, 'r1'])
    const sent = w.submits[w.submits.length - 1]
    expect(sent.origin.kind).toBe('plugin')
    expect(record.stdin).toBe(sent.text)
    expect(sent.text).toContain('넓게')
    expect(writes.slice(before)).toEqual([null])
  })

  test('초안이 있으면 수령하지 않는다', async ($, on) => {
    const form = normalizeForm(twoQuestions() as unknown as FormInput)
    const rec = openRecord({ id: 'f-0000abcd', toolUseId: 'tu-x', form, drafts: { why: { selected: [], other: '쓰던 글', note: '' } }, sessionId: SID, now: 1_000_000 })
    const { w, clock } = world(on, { store: { [`questionForm.open.${SID}`]: rec } })
    await start($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut({ reply_id: 'r1', picks: [{ id: 'scope', label: '넓게' }] })
    w.replies['form-pick'] = 'r1\n'
    await clock.advance(SCAN_MS)
    expect(seamSubs(w)).toContain('scan')
    expect(seamSubs(w)).not.toContain('form-pick')
    expect(seamSubs(w)).not.toContain('form-record')
  })

  test('수령하는 사이 사람이 질문지를 닫아 소비하지 못하면 기록 없이 수령 표지를 거둔다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    await openForm($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut({ reply_id: 'r1', picks: [{ id: 'scope', label: '넓게' }] })
    w.replies['form-pick'] = 'r1\n'
    w.before['form-pick'] = () => clock.sleep(1000)
    await clock.advance(SCAN_MS)
    const ui = await mount($)
    await ui.press({ key: 'cancel' })
    await clock.advance(1000)
    expect(seamSubs(w)).toEqual(['cleanup', 'scan', 'form-pick', 'form-unpick'])
    expect(JSON.parse(w.seams[3].stdin ?? '{}')).toEqual({ session_id: SID })
    expect(w.seams[3].args).toEqual(['r1'])
  })

  test('엔진이 제출을 드롭하면 적용 기록 없이 수령 표지를 거둔다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    await openForm($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut({ reply_id: 'r1', picks: [{ id: 'scope', label: '넓게' }] })
    w.replies['form-pick'] = 'r1\n'
    w.submitDrop = 'host limit'
    const sent = w.submits.length
    await clock.advance(SCAN_MS)
    expect(w.submits).toHaveLength(sent + 1)
    expect(seamSubs(w)).toEqual(['cleanup', 'scan', 'form-pick', 'form-unpick'])
    expect(w.seams[3].args).toEqual(['r1'])
    expect(JSON.parse(w.seams[3].stdin ?? '{}')).toEqual({ session_id: SID })
  })

  test('수령 표지가 이 세션의 것이 아니면 적용하지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    await openForm($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut({ reply_id: 'r1', picks: [{ id: 'scope', label: '넓게' }] })
    w.replies['form-pick'] = ''
    const sent = w.submits.length
    await clock.advance(SCAN_MS)
    expect(seamSubs(w)).toEqual(['cleanup', 'scan', 'form-pick'])
    expect(w.submits).toHaveLength(sent)
  })

  test('살필 것이 앞 틱과 같으면 60초 안에는 scan 을 다시 부르지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    // 차례가 도는 동안이라 쉼 여부가 바뀌지 않는다.
    await turnStart($)
    await openForm($)
    w.dirs[OWN] = ['r1.json']
    w.replies.scan = scanOut(null)
    await clock.advance(SCAN_MS * 4)
    expect(seamSubs(w).filter(s => s === 'scan')).toHaveLength(1)
    await clock.advance(SCAN_MS)
    expect(seamSubs(w).filter(s => s === 'scan')).toHaveLength(2)
  })
})

describe('깨우기', () => {
  test('쉰 지 45초가 되면 플러그인 출처로 리터럴 하나를 낸다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await clock.advance(IDLE_MS - SCAN_MS)
    expect(seamSubs(w)).not.toContain('wake-mark')
    await clock.advance(SCAN_MS)
    const mark = w.seams.find(c => c.sub === 'wake-mark')
    expect(mark?.args).toEqual(['run-1', 'r9'])
    expect(JSON.parse(mark?.stdin ?? '{}')).toEqual({ session_id: SID })
    expect(w.submits).toEqual([{ text: LITERAL, origin: expect.objectContaining({ kind: 'plugin' }) }])
  })

  test('차례가 돌고 있으면 깨우지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await turnStart($)
    await clock.advance(IDLE_MS * 3)
    expect(seamSubs(w)).not.toContain('wake-mark')
  })

  test('하위 에이전트의 차례는 쉼 판정에 들지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await turnStart($, 'agent-1')
    await clock.advance(IDLE_MS + SCAN_MS)
    expect(seamSubs(w)).toContain('wake-mark')
  })

  test('틱 하나에 하나만 깨운다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE, { ...WAKE, reply_id: 'r10' }])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await clock.advance(IDLE_MS)
    expect(seamSubs(w).filter(s => s === 'wake-mark')).toHaveLength(1)
  })

  test('정규식에 맞지 않는 줄은 내지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = '<cc-remote-approval run=run-1 id=a/>\n'
    await start($)
    await clock.advance(IDLE_MS)
    expect(seamSubs(w)).toContain('wake-mark')
    expect(w.submits).toHaveLength(0)
  })

  test('사람 입력이 있으면 그때부터 45초를 다시 센다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await clock.advance(40_000)
    await $.prompt.change({ text: '이전 글', cursor: 0, origin: { kind: 'history' } })
    await clock.advance(20_000)
    expect(seamSubs(w)).not.toContain('wake-mark')
    await clock.advance(30_000)
    expect(seamSubs(w)).toContain('wake-mark')
  })

  test('플러그인 출처 제출은 사람 입력이 아니다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await clock.advance(40_000)
    await prompt($, '플러그인 글', { kind: 'plugin', name: 'other' })
    await clock.advance(SCAN_MS)
    expect(seamSubs(w)).toContain('wake-mark')
  })

  test('session.start 가 다시 오면 차례 상태를 쉼으로 되돌린다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await turnStart($)
    await start($)
    await clock.advance(IDLE_MS)
    expect(seamSubs(w)).toContain('wake-mark')
  })

  test('turn.complete 없이 남은 돌고 있음은 다음 차례의 turn.complete 로 풀린다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null, [WAKE])
    w.replies['wake-mark'] = `${LITERAL}\n`
    await start($)
    await turnStart($)
    await clock.advance(IDLE_MS * 2)
    expect(seamSubs(w)).not.toContain('wake-mark')
    await turnStart($)
    await turnDone($)
    await clock.advance(SCAN_MS * 5)
    expect(seamSubs(w)).toContain('wake-mark')
  })
})

describe('시계 복구', () => {
  test('살핌 주기가 거부되어 끝나면 사람 사건 없이 감시 주기가 다시 건다', async ($, on) => {
    const { w, clock } = world(on)
    runMailbox(w)
    w.replies.scan = scanOut(null)
    w.refusedEvery.add(SCAN_MS)
    await start($)
    await clock.advance(SCAN_MS * 2)
    expect(seamSubs(w)).not.toContain('scan')
    w.refusedEvery.delete(SCAN_MS)
    // 감시 주기는 80초 틱에서 살핌이 45초 넘게 멈춘 것을 보고 다시 걸고, 95초에 첫 살핌이 돈다.
    await clock.advance(70_000)
    expect(seamSubs(w)).toContain('scan')
  })
})
