// 런 상태 패널 mod. 대화형 세션에서만 깨어나, 상태 표시줄이 고른 런 하나의 상태를
// orchestrator/run-pane.sh 에서 받아 패널에 그린다. 문구·순서·색조·부류·주기는 모두
// 그 헬퍼가 정하고, 이 모듈은 언제 헬퍼를 부르고 언제 패널을 여닫는지만 정한다.
import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type { PaneControl, PaneLine, PaneSnapshot } from '../types'

type Dollar = Parameters<Hook<'session.start'>>[0]

const PANE = 'autopilot-status'
const TITLE = 'autopilot'
const TICK_MS = 10_000
const IDLE_MS = 60_000
const HELPER_TIMEOUT_MS = 8000
// 런 id 기록이 세션 내내 쌓이지 않게 끝에서부터 이만큼만 남긴다.
const KEEP_IDS = 100

const snapshot = atom({ plugin: 'cc-cmds', key: 'paneSnapshot' } as const, {
  lines: [],
  warning: null,
} as PaneSnapshot)

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

// 헬퍼 출력 규약: 머리 행 `cc-pane<TAB>1<TAB>부류<TAB>rid<TAB>목록 경로<TAB>refresh_ms`,
// 이어서 `tone<TAB>text` 본문. 머리 행이 규약과 다르면 undefined.
const parse = (stdout: string): { head: Head; lines: PaneLine[] } | undefined => {
  const rows = stdout.split('\n').filter(row => row !== '')
  const cells = rows.length > 0 ? rows[0].split('\t') : []
  if (cells.length !== 6 || cells[0] !== 'cc-pane' || cells[1] !== '1') return undefined
  const refreshMs = Number(cells[5])
  const head: Head = {
    kind: cells[2],
    rid: cells[3] === '-' || cells[3] === '' ? null : cells[3],
    indexPath: cells[4].startsWith('/') ? cells[4] : null,
    refreshMs: Number.isFinite(refreshMs) && refreshMs > 0 ? refreshMs : IDLE_MS,
  }
  const lines = rows.slice(1).map(row => {
    const tab = row.indexOf('\t')

    return tab < 0 ? { tone: 'normal', text: row } : { tone: row.slice(0, tab), text: row.slice(tab + 1) }
  })

  return { head, lines }
}

const remember = (ids: readonly string[], id: string): string[] =>
  ids.includes(id) ? [...ids] : [...ids, id].slice(-KEEP_IDS)

// ui.close 뒤의 닫힘 기록. 사람이 닫은 것만 현재 rid 로 기록한다. 명령의 닫기(plugin)는
// 명령 처리기가 직접 기록하고, 적재 해제(unload)는 기록하지 않는다.
export const noteClose = (c: PaneControl, origin: string): PaneControl =>
  origin === 'person' && c.rid !== null ? { ...c, dismissedFor: remember(c.dismissedFor, c.rid) } : c

// tone 을 테마 키나 Text 속성으로 바꾼다. 모르는 tone 은 속성 없이 그린다.
const toneProps = (tone: string) => {
  switch (tone) {
    case 'ok':
      return { color: 'success' } as const
    case 'warn':
      return { color: 'warning' } as const
    case 'error':
      return { color: 'error', bold: true } as const
    case 'accent':
      return { color: 'suggestion' } as const
    case 'dim':
      return { dimColor: true } as const
    default:
      return {}
  }
}

// 헬퍼는 한 번에 하나만 돈다. 모듈이 다시 적재되면 이전 시계도 함께 사라지므로
// 이 둘은 모듈 변수로 둔다.
let isRunning = false
let timer: { cancel: () => void } | undefined

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
// 더하며, 자동으로 열지 않는다. tickPath 는 tickMtime 을 잰 목록 경로다.
async function runHelper($: Dollar, sid: string, tickMtime: number | null, tickPath: string | null) {
  if (isRunning) return
  isRunning = true
  try {
    let parsed: ReturnType<typeof parse>
    let failure: string | null = null
    try {
      const ran = await $.process.run(['bash', `${$.plugin.root}/orchestrator/run-pane.sh`, sid], {
        timeoutMs: HELPER_TIMEOUT_MS,
      })
      parsed = ran.exitCode === 0 ? parse(ran.stdout) : undefined
      if (ran.exitCode !== 0) failure = `종료 코드 ${ran.exitCode}`
      else if (parsed === undefined) failure = '출력 형식이 맞지 않음'
    } catch {
      failure = '실행하지 못함'
    }
    const now = await $.clock.now()

    if (parsed === undefined) {
      await update($, snapshot, s => ({ ...s, warning: `⚠ 런 상태를 읽지 못했다 (${failure})` }))
      await update($, control, c => ({ ...c, lastRunAt: now, lastSid: sid, lastMtime: tickMtime }))

      return
    }

    const { head, lines } = parsed
    const mtime = head.indexPath === tickPath ? tickMtime : await statMtime($, head.indexPath)
    await update($, snapshot, () => ({ lines, warning: null }))
    const before = await update($, control, c => ({
      ...c,
      lastRunAt: now,
      lastSid: sid,
      lastMtime: mtime,
      rid: head.rid,
      indexPath: head.indexPath,
      refreshMs: head.refreshMs,
    }))

    // 자동 열기: 살아 있는 런마다 한 번, 사람이 닫은 적 없는 런만, 패널이 이미 열려
    // 있지 않을 때만. 놓였는지가 아니라 열려 있는지로 본다 — 좁은 터미널에서 기다리는
    // 패널도 열려 있는 것이다.
    const rid = head.rid
    if (head.kind !== 'live' || rid === null) return
    if (before.autoOpenedFor.includes(rid) || before.dismissedFor.includes(rid)) return
    const panes = await $.ui.panes()
    if (panes.some(pane => pane.id === PANE)) return
    await update($, control, c => ({ ...c, autoOpenedFor: remember(c.autoOpenedFor, rid) }))
    await $.ui.open({ id: PANE, title: TITLE })
  } finally {
    isRunning = false
  }
}

// 매 틱은 프로세스 없이 세션 id·패널·목록 mtime 만 보고, 조건이 맞을 때만 헬퍼를 부른다.
async function tick($: Dollar) {
  if (isRunning) return
  const sid = await $.session.id()
  const panes = await $.ui.panes()
  const pane = panes.find(one => one.id === PANE)
  const c = await read($, control)
  const mtime = await statMtime($, c.indexPath)
  const now = await $.clock.now()
  const period = pane?.isPlaced ? c.refreshMs : IDLE_MS
  const isDue =
    c.lastRunAt === null || sid !== c.lastSid || mtime !== c.lastMtime || now - c.lastRunAt >= period
  if (isDue) await runHelper($, sid, mtime, c.indexPath)
}

export const register: Register = on => {
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
    timer?.cancel()
    timer = $.clock.every(TICK_MS, () => {
      tick($).catch(() => undefined)
    })

    return next(e)
  })

  // 명령은 「놓여 있음」으로 토글한다. 사람이 보는 것은 놓인 패널뿐이기 때문이다.
  on('command.run', { command: 'autopilot-status' }, async $ => {
    const pane = (await $.ui.panes()).find(one => one.id === PANE)
    if (pane?.isPlaced) {
      // 이 닫기는 출처가 plugin 으로 오므로 ui.close 훅이 기록하지 않는다. 여기서 기록한다.
      const { rid } = await read($, control)
      if (rid !== null) await update($, control, c => ({ ...c, dismissedFor: remember(c.dismissedFor, rid) }))
      await $.ui.close({ id: PANE })

      return {}
    }
    await $.ui.open({ id: PANE, title: TITLE })
    const sid = await $.session.id()
    const c = await read($, control)
    await runHelper($, sid, await statMtime($, c.indexPath), c.indexPath)

    return {}
  })

  // 사람이 닫은 런으로는 다시 저절로 열지 않는다. 기록이 실패해도 닫기는 막지 않는다.
  on('ui.close', async ($, e, next) => {
    if (e.id === PANE && e.origin.kind === 'person') await update($, control, c => noteClose(c, 'person'))

    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const { lines, warning } = await read($, snapshot)

    return (
      <Box flexDirection="column">
        {lines.length === 0 && warning === null && <Text dimColor>런 상태를 읽는 중</Text>}
        {lines.map(line => (
          <Text {...toneProps(line.tone)} wrap="truncate-end">
            {line.text}
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
}
