// 런 상태 패널 mod 시험. 엔진 밑의 세계(세션 id, 패널, stat, 헬퍼 프로세스, 시계, 환경)를
// 모두 스텁으로 세우고, 세계 연산의 스텁은 모두 { value } 형식으로 답한다.
import type { On, UiPane } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import type { PaneControl } from '../types'
import { noteClose } from './autopilot-status'

const PANE = 'autopilot-status'
const IDX = '/state/cc-cmds/session/sid-1'
const TICK = 10_000

type Reply = { exitCode: number; stdout: string } | 'reject'

const head = (kind: string, rid: string, refresh = kind === 'live' ? 10000 : 60000) =>
  `cc-pane\t1\t${kind}\t${rid}\t${IDX}\t${refresh}`
const out = (kind: string, rid: string, body: string[] = ['normal\t머리 줄']) =>
  ({ exitCode: 0, stdout: [head(kind, rid), ...body].join('\n') + '\n' }) as Reply

// 세계 하나: 시험이 바꾸는 값(w.*)과 엔진 밑에서 일어난 일의 기록.
const world = (on: On, env: Record<string, string> = {}) => {
  const w = {
    sid: 'sid-1',
    reply: out('none', '-', ['dim\t연결된 런 없음']),
    mtime: 1 as number | null,
    placeOnOpen: true,
    panes: [] as UiPane[],
    registered: [] as string[],
    runs: [] as string[][],
    opens: [] as string[],
    closes: [] as string[],
    inFlight: 0,
    maxInFlight: 0,
    helperDelayMs: 0,
  }
  mock.env(on, env)
  const clock = mock.clock(on, { now: 1_000_000 })
  // session.start 는 세계 연산이 아니라 이벤트라서 결과를 그대로 돌려준다.
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    w.registered.push(e.name)

    return { value: undefined }
  })
  on('session.id', () => ({ value: w.sid }))
  on('ui.panes', () => ({ value: [...w.panes] }))
  on('ui.open', (_$, e) => {
    w.opens.push(e.id)
    w.panes = [
      ...w.panes.filter(pane => pane.id !== e.id),
      { id: e.id, title: e.title ?? e.id, isShown: true, isFocused: false, isPlaced: w.placeOnOpen },
    ]

    return { value: w.placeOnOpen ? { isPlaced: true } : { isPlaced: false, reason: '144칸 아래' } }
  })
  on('ui.close', (_$, e) => {
    w.closes.push(e.origin.kind)
    w.panes = w.panes.filter(pane => pane.id !== e.id)

    return { value: undefined }
  })
  on('fs.stat', () => {
    if (w.mtime === null) throw Object.assign(new Error('ENOENT: no such file or directory'), { code: 'ENOENT' })

    return { value: { kind: 'file', size: 1, mtimeMs: w.mtime, isLink: false } }
  })
  on('process.run', async (_$, e) => {
    w.runs.push([...e.argv])
    w.inFlight += 1
    w.maxInFlight = Math.max(w.maxInFlight, w.inFlight)
    try {
      if (w.helperDelayMs > 0) await clock.sleep(w.helperDelayMs)
      const reply = w.reply
      if (reply === 'reject') throw new Error('timed out')

      return {
        value: { exitCode: reply.exitCode, stdout: reply.stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
      }
    } finally {
      w.inFlight -= 1
    }
  })

  return { w, clock }
}

const start = ($: any, isInteractive = true) =>
  $.session.start({ cwd: '/work', surface: isInteractive ? 'terminal' : null, isInteractive })

const toggle = ($: any) =>
  $.command.run({
    command: 'autopilot-status',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })

const mount = ($: any) =>
  $.ui.mount({
    plugin: 'cc-cmds',
    surface: 'terminal',
    component: 'Pane',
    requestId: PANE,
    props: {
      title: 'autopilot',
      isFocused: false,
      bodyColumns: 60,
      placement: 'dock',
      scroll: { offset: 0, bodyRows: 20 },
      view: {},
    },
  })

describe('시작과 가드', () => {
  test('대화형 시작은 명령을 한 번 등록하고 첫 틱에 헬퍼를 한 번 돌린다', async ($, on) => {
    const { w, clock } = world(on)
    await start($)
    expect(w.registered).toEqual(['autopilot-status'])
    expect(w.runs).toHaveLength(0)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    expect(w.runs[0][0]).toBe('bash')
    expect(w.runs[0][1]).toMatch(/\/orchestrator\/run-pane\.sh$/)
    expect(w.runs[0][2]).toBe('sid-1')
  })

  test('비대화형 시작은 등록·프로세스·패널을 만들지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($, false)
    await clock.advance(TICK * 7)
    expect(w.registered).toHaveLength(0)
    expect(w.runs).toHaveLength(0)
    expect(w.opens).toHaveLength(0)
  })

  const pipelineEnvs: Array<[string, Record<string, string>]> = [
    ['RUN_ID 만', { CC_PIPELINE_RUN_ID: 'r1' }],
    ['STAGE_ID 만', { CC_PIPELINE_STAGE_ID: 'A' }],
    ['교대', { CC_PIPELINE_STAGE_ID: '', CC_PIPELINE_SHIFT_ID: 'sh1', CC_PIPELINE_RUN_ID: 'r1' }],
    ['셋 다', { CC_PIPELINE_RUN_ID: 'r1', CC_PIPELINE_STAGE_ID: 'A', CC_PIPELINE_SHIFT_ID: 'sh1' }],
    ['SHIFT_ID 만', { CC_PIPELINE_SHIFT_ID: 'sh1' }],
  ]
  for (const [name, env] of pipelineEnvs) {
    test(`파이프라인 환경(${name})에서는 대화형이라도 아무것도 하지 않는다`, async ($, on) => {
      const { w, clock } = world(on, env)
      w.reply = out('live', 'r1')
      await start($)
      await clock.advance(TICK * 7)
      expect(w.registered).toHaveLength(0)
      expect(w.runs).toHaveLength(0)
      expect(w.opens).toHaveLength(0)
    })
  }

  test('STAGE_ID 가 빈 문자열뿐이면 활성이다', async ($, on) => {
    const { w, clock } = world(on, { CC_PIPELINE_STAGE_ID: '' })
    await start($)
    await clock.advance(TICK)
    expect(w.registered).toEqual(['autopilot-status'])
    expect(w.runs).toHaveLength(1)
  })
})

describe('자동 열기', () => {
  test('live 에 한 번 열고, 같은 rid 로는 다시 열지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.opens).toEqual([PANE])
    await clock.advance(TICK * 3)
    expect(w.runs.length).toBeGreaterThan(1)
    expect(w.opens).toEqual([PANE])

    // 패널이 사람의 닫기 없이 사라져도(적재 해제) 이미 한 번 연 rid 로는 다시 열지 않는다.
    w.panes = []
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.opens).toEqual([PANE])
  })

  for (const isPlaced of [true, false]) {
    test(`패널이 열려 있으면(놓임=${isPlaced}) 다른 rid 는 열지도 기록하지도 않는다`, async ($, on) => {
      const { w, clock } = world(on)
      w.placeOnOpen = isPlaced
      w.reply = out('live', 'r1')
      await start($)
      await clock.advance(TICK)
      expect(w.opens).toHaveLength(1)

      w.reply = out('live', 'r2')
      w.mtime = 2
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(2)
      expect(w.opens).toHaveLength(1)

      // 기록하지 않았다면 패널이 사라진 뒤 r2 에 한 번 연다.
      w.panes = []
      w.mtime = 3
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(3)
      expect(w.opens).toHaveLength(2)
    })
  }

  test('ended 와 none 에서는 열지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK)
    w.reply = out('none', '-')
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    expect(w.opens).toHaveLength(0)
  })
})

describe('닫힘 기록', () => {
  // 시험 엔진의 $ 는 ui.close 를 세계 연산으로만 두어 사람의 닫기를 일으킬 수 없다. 그래서
  // 출처별 기록 규칙은 ui.close 훅이 쓰는 noteClose 로 확인하고, 기록된 rid 가 자동 열기를
  // 막는 것은 아래 명령 시험이 확인한다.
  const base: PaneControl = {
    autoOpenedFor: [],
    dismissedFor: ['r0'],
    lastRunAt: 1,
    lastMtime: 1,
    lastSid: 'sid-1',
    rid: 'r1',
    indexPath: IDX,
    refreshMs: 10000,
  }

  test('사람이 닫으면 현재 rid 를 기록한다', () => {
    expect(noteClose(base, 'person').dismissedFor).toEqual(['r0', 'r1'])
    expect(noteClose(noteClose(base, 'person'), 'person').dismissedFor).toEqual(['r0', 'r1'])
  })

  test('적재 해제와 mod 자신의 닫기는 기록하지 않는다', () => {
    expect(noteClose(base, 'unload')).toEqual(base)
    expect(noteClose(base, 'plugin')).toEqual(base)
  })

  test('런이 없을 때 닫으면 기록할 것이 없다', () => {
    const none = { ...base, rid: null }
    expect(noteClose(none, 'person')).toEqual(none)
  })
})

describe('명령', () => {
  test('놓여 있으면 닫고 닫힘을 기록하며, 그 뒤 자동 열기가 없다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    expect(await toggle($)).toEqual({})
    expect(w.opens).toHaveLength(1)
    expect(await toggle($)).toEqual({})
    expect(w.closes).toEqual(['plugin'])
    expect(w.panes).toHaveLength(0)
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    expect(w.opens).toHaveLength(1)
  })

  test('놓여 있지 않으면 열고 헬퍼를 한 번 돌린다', async ($, on) => {
    const { w, clock } = world(on)
    w.placeOnOpen = false
    w.reply = out('live', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.opens).toHaveLength(1)
    expect(w.runs).toHaveLength(1)
    expect(await toggle($)).toEqual({})
    expect(w.opens).toHaveLength(2)
    expect(w.runs).toHaveLength(2)
    expect(w.closes).toHaveLength(0)
  })
})

describe('실패 처리', () => {
  const failures: Array<[string, Reply]> = [
    ['스키마 2', { exitCode: 0, stdout: 'cc-pane\t2\tlive\tr9\t' + IDX + '\t10000\nnormal\t새 줄\n' }],
    ['머리 행 없음', { exitCode: 0, stdout: 'normal\t새 줄\n' }],
    ['0 이 아닌 종료', { exitCode: 1, stdout: head('live', 'r9') + '\nnormal\t새 줄\n' }],
    ['process.run 거부', 'reject'],
  ]
  for (const [name, reply] of failures) {
    test(`${name}: 마지막 줄을 두고 경고 줄을 더하며 열지 않는다`, async ($, on) => {
      const { w, clock } = world(on)
      w.reply = out('ended', 'r1', ['normal\t옛 줄'])
      await start($)
      await clock.advance(TICK)
      const ui = await mount($)
      expect(await ui.find({ type: 'Text', text: '옛 줄' })).toBeDefined()

      w.reply = reply
      w.mtime = 2
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(2)
      expect(await ui.find({ type: 'Text', text: '옛 줄' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '새 줄' })).toBeUndefined()
      expect(await ui.find({ type: 'Text', text: '런 상태를 읽지 못했다' })).toBeDefined()
      expect(w.opens).toHaveLength(0)
    })
  }
})

describe('주기', () => {
  test('놓이지 않으면 60초마다, 놓이면 refresh_ms 마다 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK * 5)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)

    w.reply = out('live', 'r1')
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(3)
    expect(w.panes[0]?.isPlaced).toBe(true)
    await clock.advance(TICK * 3)
    expect(w.runs).toHaveLength(6)
  })

  test('live 라도 패널이 놓이지 않았으면 60초마다 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.placeOnOpen = false
    w.reply = out('live', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    expect(w.panes[0]?.isPlaced).toBe(false)
    await clock.advance(TICK * 5)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
  })

  test('mtime 이나 sid 가 바뀌면 다음 틱에 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK * 2)
    expect(w.runs).toHaveLength(1)
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    w.sid = 'sid-2'
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(3)
    expect(w.runs[2][2]).toBe('sid-2')
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(3)
  })

  test('세션 목록이 ENOENT 에서 생겨나면 그 틱에 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.mtime = null
    w.reply = out('none', '-')
    await start($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    w.mtime = 5
    w.reply = out('live', 'r1')
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    expect(w.opens).toEqual([PANE])
  })

  test('실행이 겹치지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    w.helperDelayMs = 25_000
    await start($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    w.mtime = 2
    await clock.advance(TICK * 2)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.maxInFlight).toBe(1)
    expect(w.inFlight).toBe(0)
  })
})

describe('그리기', () => {
  test('tone 을 테마 키와 속성으로 바꾸고, 모르는 tone 은 속성 없이 그린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1', ['ok\t초록', 'error\t빨강', 'dim\t흐림', 'sparkle\t모름'])
    await start($)
    await clock.advance(TICK)
    const ui = await mount($)
    expect((await ui.find({ type: 'Text', text: '초록' }))?.props.color).toBe('success')
    const red = await ui.find({ type: 'Text', text: '빨강' })
    expect(red?.props.color).toBe('error')
    expect(red?.props.bold).toBe(true)
    expect((await ui.find({ type: 'Text', text: '흐림' }))?.props.dimColor).toBe(true)
    const unknown = await ui.find({ type: 'Text', text: '모름' })
    expect(unknown).toBeDefined()
    expect(unknown?.props.color).toBeUndefined()
    expect(unknown?.props.dimColor).toBeUndefined()
    expect(unknown?.props.bold).toBeUndefined()
    expect(unknown?.props.wrap).toBe('truncate-end')
  })
})
