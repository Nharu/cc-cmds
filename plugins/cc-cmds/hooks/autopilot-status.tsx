// 런 상태 패널 mod. 대화형 세션에서만 깨어나, 상태 표시줄이 고른 런 하나의 상태를
// orchestrator/run-pane.sh 에서 받아 패널에 그린다. 문구·순서·색조·부류·주기와 줄 상한은
// 모두 그 헬퍼가 정하고, 이 모듈은 언제 헬퍼를 부르고 언제 패널을 여닫는지만 정한다.
// 이 모듈이 플러그인의 유일한 `modules` 진입이며, 질문지 서브 mod 의 등록도 넘겨준다.
import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type { PaneControl, PaneLine, PaneLines, PanePart } from '../types'
import { register as registerQuestionForm } from './question-form/index'

type Dollar = Parameters<Hook<'session.start'>>[0]

const PANE = 'autopilot-status'
const TITLE = 'autopilot'
const TICK_MS = 10_000
const IDLE_MS = 60_000
const HELPER_TIMEOUT_MS = 8000
// 도크가 이 폭부터 놓이므로, 그보다 좁으면 명령이 열지 않고 안내만 띄운다.
const DOCK_MIN_COLUMNS = 110
// 도크에 요청하는 본문 폭. 헬퍼의 --cols 기본값과 같다.
const DOCK_COLUMNS = 44
// 시계가 이 시간 넘게 틱을 내지 않았으면 끝난 것으로 보고 다시 건다.
const STALL_MS = 3 * TICK_MS
const NOT_DOCKED = 'autopilot 패널은 전체 화면(110칸 이상)에서만 보입니다'
// 런 id 기록이 세션 내내 쌓이지 않게 끝에서부터 이만큼만 남긴다.
const KEEP_IDS = 100
// 헬퍼가 내는 묶음의 닫힌 집합. 여기 없는 묶음의 줄은 버린다.
const BUNDLES = new Set([
  'none',
  'title',
  'head',
  'head-detail',
  'gap',
  'seg-heading',
  'seg',
  'seg-detail',
  'seg-folded',
  'gate-none',
  'approval',
  'block-heading',
  'block-reason',
  'cone-unresolved',
  'orphan',
  'event-heading',
  'event',
])

const snapshot = atom({ plugin: 'cc-cmds', key: 'paneLines' } as const, {
  lines: [],
  warning: null,
} as PaneLines)

const control = atom({ plugin: 'cc-cmds', key: 'paneControl' } as const, {
  autoOpenedFor: [],
  dismissedFor: [],
  lastRunAt: null,
  lastMtime: null,
  lastSid: null,
  rid: null,
  indexPath: null,
  refreshMs: IDLE_MS,
} as PaneControl)

type Head = { kind: string; rid: string | null; indexPath: string | null; refreshMs: number }

// 조각 하나의 색조 `<normal|dim|ok|warn|error|accent>[.b]` 를 색조와 굵기로 나눈다.
const part = (tone: string, text: string): PanePart =>
  tone.endsWith('.b') ? { tone: tone.slice(0, -2), bold: true, text } : { tone, bold: false, text }

// 헬퍼 출력 규약 cc-pane 2: 머리 행 `cc-pane<TAB>2<TAB>부류<TAB>rid<TAB>목록 경로<TAB>refresh_ms`,
// 이어서 `묶음<TAB><cut|wrap><TAB>색조<TAB>글[<TAB>색조<TAB>글]…` 본문. 머리 행이 규약과
// 다르면 그 까닭을, 맞으면 머리와 본문을 돌려준다. 스키마는 정확히 2 만 받는다.
const parse = (stdout: string): { head: Head; lines: PaneLine[] } | string => {
  const rows = stdout.split('\n').filter(row => row !== '')
  const cells = rows.length > 0 ? rows[0].split('\t') : []
  if (cells.length !== 6 || cells[0] !== 'cc-pane') return '출력 형식이 맞지 않음'
  if (cells[1] !== '2') return `헬퍼 규약 cc-pane ${cells[1]} 은 읽지 않음`
  const refreshMs = Number(cells[5])
  const head: Head = {
    kind: cells[2],
    rid: cells[3] === '-' || cells[3] === '' ? null : cells[3],
    indexPath: cells[4].startsWith('/') ? cells[4] : null,
    refreshMs: Number.isFinite(refreshMs) && refreshMs > 0 ? refreshMs : IDLE_MS,
  }
  const lines: PaneLine[] = []
  for (const row of rows.slice(1)) {
    const [bundle, mode, ...rest] = row.split('\t')
    if (!BUNDLES.has(bundle)) continue
    const parts: PanePart[] = []
    for (let i = 0; i < rest.length; i += 2) parts.push(part(rest[i], rest[i + 1] ?? ''))
    lines.push({ bundle, wrap: mode === 'wrap', parts })
  }

  return { head, lines }
}

const remember = (ids: readonly string[], id: string): string[] =>
  ids.includes(id) ? [...ids] : [...ids, id].slice(-KEEP_IDS)

// ui.close 뒤의 닫힘 기록. 사람이 닫은 것만 현재 rid 로 기록한다. 명령의 닫기(plugin)는
// 명령 처리기가 직접 기록하고, 적재 해제(unload)는 기록하지 않는다.
export const noteClose = (c: PaneControl, origin: string): PaneControl =>
  origin === 'person' && c.rid !== null ? { ...c, dismissedFor: remember(c.dismissedFor, c.rid) } : c

// 색조를 테마 키나 Text 속성으로 바꾼다. 모르는 색조는 normal 처럼 속성 없이 그린다.
const toneProps = (tone: string, bold: boolean) => {
  const weight = bold ? ({ bold: true } as const) : {}
  switch (tone) {
    case 'ok':
      return { color: 'success', ...weight } as const
    case 'warn':
      return { color: 'warning', ...weight } as const
    case 'error':
      return { color: 'error', ...weight } as const
    case 'accent':
      return { color: 'suggestion', ...weight } as const
    case 'dim':
      return { dimColor: true, ...weight } as const
    default:
      return weight
  }
}

// 아래는 모두 모듈 변수다. 모듈이 다시 적재되면 초기값으로 돌아가고, 이전 시계도 함께
// 사라진다. 그래서 재적재 뒤에는 첫 띠 렌더 전까지 저절로 열지 않고, 첫 도크 렌더
// 전까지 헬퍼 기본 폭을 쓴다.
// 헬퍼는 한 번에 하나만 돈다.
let isRunning = false
let timer: { cancel: () => void } | undefined
// session.start 가 대화형·비파이프라인 가드를 통과해 시계를 걸었는지. 이 세션에서만
// 시계를 다시 건다.
let isArmed = false
// 마지막 틱이 시작한 시각. 시계를 건 시각이 초기값이다.
let lastTickAt = 0
// 직전 틱이 본 패널의 놓임.
let wasPlaced = false
// 띠 렌더가 알려 준 전체 화면 여부. 알기 전에는 undefined.
let layout: boolean | undefined
// 마지막 도크 렌더의 본문 폭과 행 수. 도크로 그려지기 전에는 undefined.
let dock: { columns: number; rows: number } | undefined

const isCount = (n: unknown): n is number => typeof n === 'number' && Number.isInteger(n) && n > 0

async function statMtime($: Dollar, path: string | null): Promise<number | null> {
  if (path === null || !path.startsWith('/')) return null
  try {
    return (await $.fs.stat(path)).mtimeMs
  } catch {
    // 목록이 아직 없거나 지워졌다(ENOENT). 「없음」으로 본다.
    return null
  }
}

// 헬퍼를 한 번 돌리고 결과를 상태에 반영한다. 실패하면 마지막 좋은 줄을 두고 경고 줄만
// 더하며, 자동으로 열지 않는다. tickPath 는 tickMtime 을 잰 목록 경로이고, startedAt 은
// 헬퍼를 부르기 전에 읽은 시각이다. 헬퍼가 걸린 시간을 다음 기한에 더하지 않도록
// lastRunAt 에는 이 값을 적는다.
async function runHelper($: Dollar, sid: string, tickMtime: number | null, tickPath: string | null, startedAt: number) {
  if (isRunning) return
  isRunning = true
  try {
    let parsed: ReturnType<typeof parse> = '실행하지 못함'
    let failure: string | null = null
    const size = dock === undefined ? [] : ['--cols', String(dock.columns), '--rows', String(dock.rows)]
    try {
      const ran = await $.process.run(['bash', `${$.plugin.root}/orchestrator/run-pane.sh`, sid, ...size], {
        timeoutMs: HELPER_TIMEOUT_MS,
      })
      if (ran.exitCode !== 0) failure = `종료 코드 ${ran.exitCode}`
      else parsed = parse(ran.stdout)
    } catch {
      failure = '실행하지 못함'
    }

    if (failure !== null || typeof parsed === 'string') {
      const why = failure ?? parsed
      await update($, snapshot, s => ({ ...s, warning: `⚠ 런 상태를 읽지 못했다 (${why})` }))
      await update($, control, c => ({ ...c, lastRunAt: startedAt, lastSid: sid, lastMtime: tickMtime }))

      return
    }

    const { head, lines } = parsed
    const mtime = head.indexPath === tickPath ? tickMtime : await statMtime($, head.indexPath)
    await update($, snapshot, () => ({ lines, warning: null }))
    const before = await update($, control, c => ({
      ...c,
      lastRunAt: startedAt,
      lastSid: sid,
      lastMtime: mtime,
      rid: head.rid,
      indexPath: head.indexPath,
      refreshMs: head.refreshMs,
    }))

    // 자동 열기: 전체 화면인 줄 안 세션에서, 살아 있는 런마다 한 번, 사람이 닫은 적 없는
    // 런만, 패널이 이미 열려 있지 않을 때만. 놓였는지가 아니라 열려 있는지로 본다 —
    // 좁은 터미널에서 기다리는 패널도 열려 있는 것이다.
    const rid = head.rid
    if (layout !== true || head.kind !== 'live' || rid === null) return
    if (before.autoOpenedFor.includes(rid) || before.dismissedFor.includes(rid)) return
    const panes = await $.ui.panes()
    if (panes.some(pane => pane.id === PANE)) return
    await update($, control, c => ({ ...c, autoOpenedFor: remember(c.autoOpenedFor, rid) }))
    await $.ui.open({ id: PANE, title: TITLE, columns: DOCK_COLUMNS })
  } finally {
    isRunning = false
  }
}

// 매 틱은 프로세스 없이 세션 id·패널·목록 mtime 만 보고, 조건이 맞을 때만 헬퍼를 부른다.
// 기한에는 반 틱의 여유를 둔다. 틱마다 시계를 읽기까지의 지연이 엇갈려도 놓인 live
// 패널이 한 틱을 건너뛰지 않게 하기 위해서다.
async function tick($: Dollar) {
  const now = await $.clock.now()
  lastTickAt = now
  if (isRunning) return
  const sid = await $.session.id()
  const panes = await $.ui.panes()
  const isPlaced = panes.find(one => one.id === PANE)?.isPlaced === true
  // 놓임을 알리는 사건이 없으므로, 거짓에서 참으로 바뀐 것을 본 틱에서 곧바로 돌린다.
  const becamePlaced = isPlaced && !wasPlaced
  wasPlaced = isPlaced
  const c = await read($, control)
  const mtime = await statMtime($, c.indexPath)
  const period = isPlaced ? c.refreshMs : IDLE_MS
  const isDue =
    c.lastRunAt === null ||
    sid !== c.lastSid ||
    mtime !== c.lastMtime ||
    becamePlaced ||
    now - c.lastRunAt >= period - TICK_MS / 2
  if (isDue) await runHelper($, sid, mtime, c.indexPath, now)
}

// 시계 콜백은 tick 을 기다리지 않고 곧바로 돌아온다. 그래야 주기가 고정된 채로 남는다.
const arm = ($: Dollar) => {
  timer?.cancel()
  timer = $.clock.every(TICK_MS, () => {
    tick($).catch(() => undefined)
  })
}

// 시계는 거부된 주기에서 끝날 수 있다. 시계를 건 세션에서 틱이 오래 없었으면 다시 건다.
async function rearmIfStalled($: Dollar) {
  if (!isArmed) return
  const now = await $.clock.now()
  if (now - lastTickAt <= STALL_MS) return
  lastTickAt = now
  arm($)
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    if (!e.isInteractive) return next(e)
    const segment = await $.env.get('CC_PIPELINE_SEGMENT')
    const runId = await $.env.get('CC_PIPELINE_RUN_ID')
    const stageId = await $.env.get('CC_PIPELINE_STAGE_ID')
    const shiftId = await $.env.get('CC_PIPELINE_SHIFT_ID')
    if (segment || runId || stageId || shiftId) return next(e)

    await $.command.register({
      name: 'autopilot-status',
      description: '런 상태 패널을 열거나 닫는다',
      immediate: true,
    })
    lastTickAt = await $.clock.now()
    isArmed = true
    arm($)

    return next(e)
  })

  // 명령은 「놓여 있음」으로 토글한다. 사람이 보는 것은 놓인 패널뿐이기 때문이다. 놓이지
  // 않은 패널을 도킹할 수 없는 화면이면 열지 않고 안내 한 줄만 띄운다.
  on('command.run', { command: 'autopilot-status' }, async ($, e) => {
    layout = e.presentation.isFullscreen
    await rearmIfStalled($)
    const pane = (await $.ui.panes()).find(one => one.id === PANE)
    if (pane?.isPlaced) {
      // 이 닫기는 출처가 plugin 으로 오므로 ui.close 훅이 기록하지 않는다. 여기서 기록한다.
      const { rid } = await read($, control)
      if (rid !== null) await update($, control, c => ({ ...c, dismissedFor: remember(c.dismissedFor, rid) }))
      await $.ui.close({ id: PANE })

      return {}
    }
    if (!e.presentation.isFullscreen || e.presentation.columns < DOCK_MIN_COLUMNS) {
      $.ui.toast(`${NOT_DOCKED} — plugins/cc-cmds/hooks/README.md`)

      return {}
    }
    await $.ui.open({ id: PANE, title: TITLE, columns: DOCK_COLUMNS })
    const sid = await $.session.id()
    const c = await read($, control)
    const mtime = await statMtime($, c.indexPath)
    await runHelper($, sid, mtime, c.indexPath, await $.clock.now())

    return {}
  })

  // 사람이 닫은 런으로는 다시 저절로 열지 않는다. 기록이 실패해도 닫기는 막지 않는다.
  on('ui.close', async ($, e, next) => {
    await rearmIfStalled($)
    if (e.id === PANE && e.origin.kind === 'person') await update($, control, c => noteClose(c, 'person'))

    return next(e)
  }).catch(($, e, next) => next(e))

  // 띠는 그리지 않고 지나가며, 이 세션이 전체 화면인지만 적는다. 자동 열기는 이것을 본다.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    layout = e.viewport?.isFullscreen

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    if (e.props.placement !== 'dock') return <Text dimColor wrap="truncate-end">{NOT_DOCKED}</Text>
    // 도크의 폭과 행 수는 다음 헬퍼 실행이 줄 상한과 감기 추정에 쓴다.
    const columns = e.props.bodyColumns
    const rows = e.props.scroll.bodyRows
    if (isCount(columns) && isCount(rows)) dock = { columns, rows }
    const { lines, warning } = await read($, snapshot)

    // 한 줄은 바깥 Text 하나이고 조각은 그 안의 Text 다. 그래야 조각마다 색이 남은 채
    // 줄 전체가 한 번 감기거나 한 번 잘린다. 빈 줄은 높이를 잃지 않게 공백 하나로 그린다.
    return (
      <Box flexDirection="column">
        {lines.length === 0 && warning === null && <Text dimColor>런 상태를 읽는 중</Text>}
        {lines.map(line => (
          <Text wrap={line.wrap ? 'wrap' : 'truncate-end'}>
            {line.parts.every(one => one.text === '')
              ? ' '
              : line.parts.map(one => <Text {...toneProps(one.tone, one.bold)}>{one.text}</Text>)}
          </Text>
        ))}
        {warning !== null && (
          <Text color="warning" wrap="truncate-end">
            {warning}
          </Text>
        )}
      </Box>
    )
  })

  registerQuestionForm(on, options)
}
