// 런 상태 패널 mod 시험. 엔진 밑의 세계(세션 id, 패널, stat, 헬퍼 프로세스, 시계, 환경)를
// 모두 스텁으로 세우고, 세계 연산의 스텁은 모두 { value } 형식으로 답한다.
import type { On, UiPane } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import type { PaneControl } from '../types'
import { noteClose } from './autopilot-status'

const PANE = 'autopilot-status'
const IDX = '/state/cc-cmds/session/sid-1'
const TICK = 10_000
const NOT_DOCKED = 'autopilot 패널은 전체 화면(110칸 이상)에서만 보입니다'

type Reply = { exitCode: number; stdout: string } | 'reject'

const head = (kind: string, rid: string, refresh = kind === 'live' ? 10000 : 60000, schema = '2') =>
  `cc-pane\t${schema}\t${kind}\t${rid}\t${IDX}\t${refresh}`
const out = (kind: string, rid: string, body: string[] = ['title\tcut\tnormal\t머리 줄'], refresh?: number) =>
  ({ exitCode: 0, stdout: [head(kind, rid, refresh), ...body].join('\n') + '\n' }) as Reply

// 재생 원장의 두 절단에서 헬퍼가 낸 출력(--cols 44 --rows 24). 머리 행의 목록 경로만 IDX 로
// 바꿨다. 묶음 열은 scripts/test-run-pane.sh 가 같은 절단의 헬퍼 출력과 대조한다.
const REPLAY_CUT_1 = [
  // cc-pane-replay-cut-1:begin
  'cc-pane\t2\tlive\t20261006-ef0ccf94\t' + IDX + '\t10000',
  'title\tcut\taccent.b\tautopilot 20261006-ef0ccf94',
  'head\tcut\taccent.b\t⟳ 도는중\tnormal\t  교대 3 · cc-cmds · 절단점 머지',
  'head-detail\tcut\tdim\t원장 1분 안 · 워처 ♥ 1분 안 · $56.38',
  'gap\tcut\tnormal\t',
  'seg-heading\tcut\tnormal.b\t세그먼트',
  'seg\tcut\tok\t✓\tnormal\t A 머지됨',
  'seg-detail\tcut\tdim\t   리뷰 3회차 P0 0 · P1 0 · PR #1115 통과',
  'seg\tcut\taccent\t⟳\tnormal\t B 실행중',
  'seg-detail\tcut\tdim\t   implement 2회차 · 08:26Z 시작 · 선행 A',
  'gap\tcut\tnormal\t',
  'gate-none\tcut\tdim\t승인 대기 없음 · 막힘 없음',
  'gap\tcut\tnormal\t',
  'event-heading\tcut\tnormal.b\t최근 이벤트 UTC',
  'event\tcut\tdim\t07:37\tnormal\t 비용 누적 $56.38 · 스테이지 6',
  'event\tcut\tdim\t07:37\tnormal\t B implement 1회차 · rc 0',
  'event\tcut\tdim\t07:31\tnormal\t 체크 PR #1115 통과',
  'event\tcut\tdim\t07:22\tnormal\t 체크 PR #1115 대기',
  'event\tcut\tdim\t07:18\tnormal\t A 리뷰 3회차 · P0 0 · P1 0',
  'event\tcut\tdim\t07:18\tnormal\t A review 5회차 · rc 0',
  // cc-pane-replay-cut-1:end
]
const REPLAY_CUT_2 = [
  'cc-pane\t2\tlive\t20261006-ef0ccf94\t' + IDX + '\t10000',
  'title\tcut\twarn.b\tautopilot 20261006-ef0ccf94',
  'head\tcut\twarn.b\t⚠ 정지경고\tnormal\t  교대 3 · cc-cmds · 절단점 머지',
  'head-detail\tcut\tdim\t원장 4분 전 · 워처 ♥ 1분 안 · $66.42',
  'gap\tcut\tnormal\t',
  'seg-heading\tcut\tnormal.b\t세그먼트',
  'seg\tcut\tok\t✓\tnormal\t A 머지됨',
  'seg-detail\tcut\tdim\t   리뷰 3회차 P0 0 · P1 0 · PR #1115 통과',
  'seg\tcut\terror\t▲\tnormal\t B 계획됨',
  'seg-detail\tcut\tdim\t   implement 2회차 · 의도된 park',
  'gap\tcut\tnormal\t',
  'block-heading\tcut\terror.b\t▲ 막힘 · cone B · 사람 결정 필요',
  'block-reason\twrap\tnormal\t구현 B#2 중단(precondition-failed, 계획 단계 5 편집 전): 설계가 발행 질문을 킥오프 글자 5o 로 정하나 master autopilot/SKILL.md:214 에 이미 5o(Kickoff defaults)가 있다. 선택지 5p 로 둔다 / 5o 로 두고 기존 단계를 옮긴다 / 설계를 재수렴한다 중 사람 결정 필요. 커밋 a5e9a43e·24e86570·c52618c1·79afb844 는 브랜치에 있음',
  'gap\tcut\tnormal\t',
  'event-heading\tcut\tnormal.b\t최근 이벤트 UTC',
  'event\tcut\tdim\t08:03\tnormal\t 막힘 cone B 기록',
  'event\tcut\tdim\t08:03\tnormal\t 비용 누적 $66.42 · 스테이지 7',
  'event\tcut\tdim\t08:03\tnormal\t B implement 2회차 · rc 0 · park',
]
const replay = (rows: string[]) => ({ exitCode: 0, stdout: rows.join('\n') + '\n' }) as Reply

// 세계 하나: 시험이 바꾸는 값(w.*)과 엔진 밑에서 일어난 일의 기록.
const world = (on: On, env: Record<string, string> = {}) => {
  const w = {
    sid: 'sid-1',
    reply: out('none', '-', ['none\tcut\tdim\t연결된 런 없음']),
    mtime: 1 as number | null,
    placeOnOpen: true,
    panes: [] as UiPane[],
    registered: [] as string[],
    runs: [] as string[][],
    opens: [] as string[],
    openColumns: [] as Array<number | undefined>,
    closes: [] as string[],
    toasts: [] as string[],
    inFlight: 0,
    maxInFlight: 0,
    helperDelayMs: 0,
    // 참이면 stat 두 번에 한 번 400 ms 를 잔다.
    isStatSlow: false,
    statCalls: 0,
    // 참이면 시계의 다음 주기를 거부해 간격을 끝낸다.
    isEveryRefused: false,
  }
  mock.env(on, env)
  // mock.clock 도 clock.every 를 받으므로, 이 훅은 mod 의 주기에만 매처로 걸고 먼저 둔다.
  on('clock.every', { ms: TICK }, (_$, e, next) => (w.isEveryRefused ? { deny: '주기 거부' } : next(e)))
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
    w.openColumns.push(e.columns)
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
  // 띠 아래의 엔진: mod 의 띠 훅이 next 로 넘기면 빈 상자를 그린다.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Box({}))
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)

    return { value: undefined }
  })
  on('fs.stat', async () => {
    w.statCalls += 1
    if (w.isStatSlow && w.statCalls % 2 === 0) await clock.sleep(400)
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

const toggle = ($: any, presentation = { isFullscreen: true, columns: 120 }) =>
  $.command.run({
    command: 'autopilot-status',
    args: '',
    origin: { kind: 'composer' },
    presentation,
  })

// 띠를 한 번 그려 이 세션의 레이아웃을 알린다. 자동 열기는 이것이 참일 때만 연다.
const band = ($: any, isFullscreen = true) =>
  $.ui.mount({
    plugin: 'cc-cmds',
    surface: 'terminal',
    component: 'AbovePrompt',
    viewport: { columns: 160, rows: 48, isFullscreen },
    props: {
      hasSurvey: false,
      isWorking: false,
      maxRows: 10,
      bodyColumns: 155,
      scroll: { offset: 0, bodyRows: 9 },
      view: {},
    },
  })

const mount = ($: any, placement: 'dock' | 'inline' = 'dock', bodyColumns = 60, bodyRows = 20) =>
  $.ui.mount({
    plugin: 'cc-cmds',
    surface: 'terminal',
    component: 'Pane',
    requestId: PANE,
    props: {
      title: 'autopilot',
      isFocused: false,
      bodyColumns,
      placement,
      scroll: { offset: 0, bodyRows },
      view: {},
    },
  })

// 그려진 요소가 보이는 글 전부. 안쪽 Text 의 글까지 문서 순서로 잇는다.
const shown = (node: unknown): string => {
  if (typeof node === 'string') return node
  if (node === null || typeof node !== 'object') return ''
  const el = node as { children?: unknown[]; text?: string }
  if (Array.isArray(el.children) && el.children.length > 0) return el.children.map(shown).join('')

  return el.text ?? ''
}

// 조각 하나는 wrap 속성이 없는 안쪽 Text 다. 바깥 Text 도 안쪽 글을 보이므로 함께 걸러 낸다.
const piece = async (ui: any, text: string) =>
  ((await ui.findAll({ type: 'Text', text })) as Array<{ props: Record<string, unknown> }>).find(
    el => el.props.wrap === undefined,
  )

// 줄 하나는 wrap 속성을 가진 바깥 Text 다. 그려진 순서대로 그 줄들을 돌려준다.
const drawnLines = async (ui: any) =>
  ((await ui.findAll({ type: 'Text' })) as Array<{ props: Record<string, unknown>; children: unknown[] }>).filter(
    el => el.props.wrap === 'truncate-end' || el.props.wrap === 'wrap',
  )

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
      await band($)
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
  test('live 에 한 번 44칸으로 열고, 같은 rid 로는 다시 열지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    await band($)
    await clock.advance(TICK)
    expect(w.opens).toEqual([PANE])
    expect(w.openColumns).toEqual([44])
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
      await band($)
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
    await band($)
    await clock.advance(TICK)
    w.reply = out('none', '-')
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    expect(w.opens).toHaveLength(0)
  })
})

describe('레이아웃', () => {
  test('띠가 그려지기 전에는 live 라도 저절로 열지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    await clock.advance(TICK * 3)
    expect(w.runs.length).toBeGreaterThan(0)
    expect(w.opens).toHaveLength(0)
  })

  test('띠가 메인 화면이라고 하면 열지 않고, 전체 화면이라고 바뀐 뒤에 연다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    await band($, false)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    expect(w.opens).toHaveLength(0)

    await band($, true)
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
    expect(w.opens).toEqual([PANE])
  })

  test('명령이 본 레이아웃도 자동 열기 조건이 된다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    await band($, true)
    // 메인 화면의 명령은 안내만 띄우고, 이 세션을 전체 화면이 아닌 것으로 적는다.
    expect(await toggle($, { isFullscreen: false, columns: 200 })).toEqual({})
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
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
    await band($)
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

  test('놓여 있으면 메인 화면의 명령도 닫는다', async ($, on) => {
    const { w } = world(on)
    w.reply = out('live', 'r1')
    await start($)
    expect(await toggle($)).toEqual({})
    expect(w.opens).toHaveLength(1)
    expect(await toggle($, { isFullscreen: false, columns: 80 })).toEqual({})
    expect(w.closes).toEqual(['plugin'])
    expect(w.toasts).toHaveLength(0)
  })

  const narrow: Array<[string, { isFullscreen: boolean; columns: number }]> = [
    ['메인 화면', { isFullscreen: false, columns: 200 }],
    ['110칸 미만 전체 화면', { isFullscreen: true, columns: 109 }],
  ]
  for (const [name, presentation] of narrow) {
    test(`${name}에서는 열지 않고 안내를 한 번 띄운다`, async ($, on) => {
      const { w } = world(on)
      w.reply = out('live', 'r1')
      await start($)
      expect(await toggle($, presentation)).toEqual({})
      expect(w.toasts).toEqual([`${NOT_DOCKED} — plugins/cc-cmds/hooks/README.md`])
      expect(w.opens).toHaveLength(0)
      expect(w.runs).toHaveLength(0)
    })
  }

  test('110칸 전체 화면에서 놓여 있지 않으면 44칸으로 열고 헬퍼를 한 번 돌린다', async ($, on) => {
    const { w, clock } = world(on)
    w.placeOnOpen = false
    w.reply = out('live', 'r1')
    await start($)
    await band($)
    await clock.advance(TICK)
    expect(w.opens).toHaveLength(1)
    expect(w.runs).toHaveLength(1)
    expect(await toggle($, { isFullscreen: true, columns: 110 })).toEqual({})
    expect(w.opens).toHaveLength(2)
    expect(w.openColumns).toEqual([44, 44])
    expect(w.runs).toHaveLength(2)
    expect(w.closes).toHaveLength(0)
    expect(w.toasts).toHaveLength(0)
  })
})

describe('실패 처리', () => {
  const failures: Array<[string, Reply]> = [
    ['스키마 1', { exitCode: 0, stdout: head('live', 'r9', 10000, '1') + '\ntitle\tcut\tnormal\t새 줄\n' }],
    ['스키마 3', { exitCode: 0, stdout: head('live', 'r9', 10000, '3') + '\ntitle\tcut\tnormal\t새 줄\n' }],
    ['머리 행 없음', { exitCode: 0, stdout: 'title\tcut\tnormal\t새 줄\n' }],
    ['0 이 아닌 종료', { exitCode: 1, stdout: head('live', 'r9') + '\ntitle\tcut\tnormal\t새 줄\n' }],
    ['process.run 거부', 'reject'],
  ]
  for (const [name, reply] of failures) {
    test(`${name}: 마지막 줄을 두고 경고 줄을 더하며 열지 않는다`, async ($, on) => {
      const { w, clock } = world(on)
      w.reply = out('ended', 'r1', ['title\tcut\tnormal\t옛 줄'])
      await start($)
      await band($)
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
    await band($)
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

  // 헬퍼가 걸린 시간이 다음 기한에 더해지면 놓인 패널이 한 틱씩 건너뛴다.
  for (const delay of [250, 1500, 4000, 8000]) {
    test(`헬퍼가 ${delay} ms 걸려도 놓인 live 패널은 매 틱 돈다`, async ($, on) => {
      const { w, clock } = world(on)
      w.reply = out('live', 'r1')
      await start($)
      await band($)
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(1)
      expect(w.panes[0]?.isPlaced).toBe(true)
      // 실행 수는 헬퍼를 부를 때 센다. 지연은 패널이 놓인 뒤부터 건다.
      w.helperDelayMs = delay
      for (let i = 2; i <= 12; i += 1) {
        await clock.advance(TICK)
        expect(w.runs).toHaveLength(i)
      }
      expect(w.maxInFlight).toBe(1)
    })
  }

  test('틱마다 stat 지연이 엇갈려도 놓인 live 패널은 매 틱 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('live', 'r1')
    w.isStatSlow = true
    await start($)
    await band($)
    // 늦은 stat 뒤의 실행까지 보이도록 틱보다 0.5초 뒤에서 센다.
    await clock.advance(TICK + 500)
    expect(w.runs).toHaveLength(1)
    for (let i = 2; i <= 12; i += 1) {
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(i)
    }
  })

  test('live 라도 패널이 놓이지 않았으면 60초마다 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.placeOnOpen = false
    w.reply = out('live', 'r1')
    await start($)
    await band($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    expect(w.panes[0]?.isPlaced).toBe(false)
    w.helperDelayMs = 250
    await clock.advance(TICK * 5)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
  })

  test('기다리던 패널이 놓인 것을 본 틱에서 주기와 상관없이 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.placeOnOpen = false
    // 놓인 뒤의 주기도 60초라, 이 틱의 실행은 놓임 전환에서만 온다.
    w.reply = out('live', 'r1', undefined, 60000)
    await start($)
    await band($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)
    w.panes = w.panes.map(pane => ({ ...pane, isPlaced: true }))
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(2)
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
    await band($)
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

describe('감시', () => {
  test('주기가 거부돼 끝난 시계를 명령이 다시 걸고, 그 시계는 훅이 끝난 뒤에도 돈다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.runs).toHaveLength(1)

    // 이미 청한 주기 하나는 돌고, 그다음 주기가 거부되어 간격이 끝난다.
    w.isEveryRefused = true
    for (let i = 0; i < 5; i += 1) {
      w.mtime = (w.mtime ?? 0) + 1
      await clock.advance(TICK)
    }
    expect(w.runs).toHaveLength(2)

    w.isEveryRefused = false
    expect(await toggle($, { isFullscreen: false, columns: 80 })).toEqual({})
    expect(w.runs).toHaveLength(2)
    for (let i = 3; i <= 6; i += 1) {
      w.mtime = (w.mtime ?? 0) + 1
      await clock.advance(TICK)
      expect(w.runs).toHaveLength(i)
    }
  })

  test('첫 틱 전의 명령은 시계를 다시 걸지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK / 2)
    expect(await toggle($, { isFullscreen: false, columns: 80 })).toEqual({})
    // 다시 걸었다면 다음 틱은 명령 뒤 10초에 온다.
    await clock.advance(TICK / 2)
    expect(w.runs).toHaveLength(1)
  })

  // 시험의 $ 에는 사람의 닫기가 없으므로, 놓인 패널을 명령으로 닫아 ui.close 훅까지 지나게 한다.
  test('시계를 걸지 않은 세션의 명령과 닫기는 시계를 걸지 않는다', async ($, on) => {
    const { w, clock } = world(on)
    await start($, false)
    await clock.advance(TICK * 7)
    w.panes = [{ id: PANE, title: 'autopilot', isShown: true, isFocused: false, isPlaced: true }]
    expect(await toggle($)).toEqual({})
    expect(w.closes).toEqual(['plugin'])
    await clock.advance(TICK * 7)
    expect(w.runs).toHaveLength(0)
  })
})

describe('그리기', () => {
  test('색조를 테마 키와 속성으로 바꾸고, .b 는 굵게, 모르는 색조는 속성 없이 그린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1', [
      'title\tcut\tok\t초록',
      'head\tcut\terror.b\t빨강',
      'head-detail\tcut\tdim\t흐림',
      'seg\tcut\tsparkle\t모름',
    ])
    await start($)
    await clock.advance(TICK)
    const ui = await mount($)
    const green = await piece(ui, '초록')
    expect(green?.props.color).toBe('success')
    expect(green?.props.bold).toBeUndefined()
    const red = await piece(ui, '빨강')
    expect(red?.props.color).toBe('error')
    expect(red?.props.bold).toBe(true)
    expect((await piece(ui, '흐림'))?.props.dimColor).toBe(true)
    const unknown = await piece(ui, '모름')
    expect(unknown).toBeDefined()
    expect(unknown?.props.color).toBeUndefined()
    expect(unknown?.props.dimColor).toBeUndefined()
    expect(unknown?.props.bold).toBeUndefined()
  })

  test('여러 조각의 줄은 바깥 Text 하나 안에 조각마다 안쪽 Text 로 그린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1', ['seg\tcut\tok\t✓\tnormal\t A 머지됨', 'block-reason\twrap\tnormal\t긴 사유'])
    await start($)
    await clock.advance(TICK)
    const ui = await mount($)
    const lines = await drawnLines(ui)
    expect(lines).toHaveLength(2)
    expect(lines[0].props.wrap).toBe('truncate-end')
    expect(lines[0].children).toHaveLength(2)
    const [glyph, rest] = lines[0].children as Array<{ type: string; props?: Record<string, unknown> }>
    expect(glyph.type).toBe('Text')
    expect(glyph.props?.color).toBe('success')
    expect(rest.type).toBe('Text')
    expect(rest.props?.color).toBeUndefined()
    expect(shown(lines[0])).toBe('✓ A 머지됨')
    expect(lines[1].props.wrap).toBe('wrap')
    expect(shown(lines[1])).toBe('긴 사유')
  })

  test('모르는 묶음의 줄은 버린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1', ['title\tcut\tnormal\t남는 줄', 'sparkle\tcut\tnormal\t버릴 줄'])
    await start($)
    await clock.advance(TICK)
    const ui = await mount($)
    expect(await ui.find({ type: 'Text', text: '남는 줄' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '버릴 줄' })).toBeUndefined()
  })

  test('인라인 자리에서는 본문 대신 흐린 한 줄을 그린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1', ['title\tcut\tnormal\t본문 줄'])
    await start($)
    await clock.advance(TICK)
    const ui = await mount($, 'inline')
    const line = await ui.find({ type: 'Text', text: NOT_DOCKED })
    expect(line?.props.dimColor).toBe(true)
    expect(await ui.find({ type: 'Text', text: '본문 줄' })).toBeUndefined()
  })

  test('도크 렌더의 폭과 행 수만 다음 헬퍼 실행에 넘기고, 인라인 렌더의 값은 버린다', async ($, on) => {
    const { w, clock } = world(on)
    w.reply = out('ended', 'r1')
    await start($)
    await clock.advance(TICK)
    expect(w.runs[0]).toHaveLength(3)

    const docked = await mount($, 'dock', 52, 31)
    w.mtime = 2
    await clock.advance(TICK)
    expect(w.runs[1].slice(2)).toEqual(['sid-1', '--cols', '52', '--rows', '31'])

    await docked.unmount()
    await mount($, 'inline', 30, 7)
    w.mtime = 3
    await clock.advance(TICK)
    expect(w.runs[2].slice(2)).toEqual(['sid-1', '--cols', '52', '--rows', '31'])
  })
})

describe('재생', () => {
  const cuts: Array<[string, string[]]> = [
    ['절단 1', REPLAY_CUT_1],
    ['절단 2', REPLAY_CUT_2],
  ]
  for (const [name, rows] of cuts) {
    test(`${name}의 헬퍼 출력을 묶음 순서대로 한 줄씩 그린다`, async ($, on) => {
      const { w, clock } = world(on)
      w.reply = replay(rows)
      await start($)
      await clock.advance(TICK)
      const ui = await mount($)
      const lines = await drawnLines(ui)
      const body = rows.slice(1).map(row => row.split('\t'))
      expect(lines).toHaveLength(body.length)
      body.forEach((cells, i) => {
        const text = cells.slice(2).filter((_, j) => j % 2 === 1).join('')
        expect(lines[i].props.wrap).toBe(cells[1] === 'wrap' ? 'wrap' : 'truncate-end')
        expect(shown(lines[i])).toBe(text === '' ? ' ' : text)
      })
    })
  }
})
