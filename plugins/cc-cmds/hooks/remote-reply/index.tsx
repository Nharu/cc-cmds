// 원격 선택지 답 모드. 중계가 우편함에 놓은 선택지 답 봉투를 이 세션의 열린 질문이나
// 질문지에 넣고, 런 주소 승인 봉투를 가져가 쉬는 라우터 좌석을 깨운다. 스풀을 읽고 쓰는
// 일(수락 판정, 수령, 적용 기록, 처리 표지, 정리)은 모두 seam.sh 가 하고, 이 모드는 `$.fs`
// 로 이름만 본 뒤 언제 무엇을 seam.sh 에 맡길지와 경합의 승자만 정한다.
// 상태 모드가 질문지 모드 다음에 이 모드를 등록한다.
import type { Hook, Register, Timer } from 'claude-code'

import { anyMarked } from '../pipeline-marks'
import { applyRemote, openFormTarget } from '../question-form/index'
import type { FormTarget } from '../question-form/index'

type Dollar = Parameters<Hook<'session.start'>>[0]

// 우편함 살핌 간격과, 살핌 주기를 지켜보는 감시 주기의 간격.
export const SCAN_MS = 15_000
export const WATCH_MS = 40_000
// 감시는 살핌의 마지막 틱이 이보다 오래면, 살핌은 감시의 마지막 틱이 이보다 오래면 다시 건다.
export const SCAN_STALL_MS = 45_000
export const WATCH_STALL_MS = 120_000
// 차례가 돌고 있지 않고 마지막 사람 입력 뒤 이만큼 지났으면 쉬고 있다.
export const IDLE_MS = 45_000
// 살필 것이 앞 틱과 같으면 이만큼 지나기 전에는 scan 을 다시 부르지 않는다.
export const RESCAN_MS = 60_000
// 정리는 활성이 된 직후와 이만큼의 틱마다.
export const CLEANUP_TICKS = 80
const SEAM_TIMEOUT_MS = 20_000

// 깨우기 리터럴의 정규식. seam.sh 가 낸 줄을 제출 전에 다시 확인한다.
export const WAKE_RE = /^<cc-remote-approval run=[A-Za-z0-9-]{1,64} id=[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}\/>$/

type Wake = { run_id: string; approval_id: string; reply_id: string }
type ScanOut = { form: { reply_id: string; picks: { id: string; label: string }[] } | null; wake: Wake[] }
type Question = { question: string; header?: string; multiSelect?: boolean; options?: { label: string }[] }

let isActive = false
let home = ''
let stateDir = ''
let scanTimer: Timer | undefined
let watchTimer: Timer | undefined
let lastScanAt = 0
let lastWatchAt = 0
let isTicking = false
let ticks = 0
// 쉼 판정: 주 루프 차례가 돌고 있는지와 마지막 사람 입력 시각.
let isTurnRunning = false
let lastHumanAt = 0
// 앞 scan 이 본 것과 그 시각.
let lastScanKey = ''
let lastScanCallAt = 0

// 표지 다섯을 리터럴로 읽는다. 셸 쪽 라우터 술어(넷)의 엄격한 상위 집합이다.
async function pipelineMarked($: Dollar): Promise<boolean> {
  return anyMarked([
    await $.env.get('CC_PIPELINE_SEGMENT'),
    await $.env.get('CC_PIPELINE_STAGE_ID'),
    await $.env.get('CC_PIPELINE_SHIFT_ID'),
    await $.env.get('CC_PIPELINE_RUN_ID'),
    await $.env.get('CC_PIPELINE_REENTRY'),
  ])
}

const spoolRoot = () => `${home}/.local/state/cc-cmds/attention`
export const safeSid = (sid: string) => sid.replace(/[^A-Za-z0-9_.-]/g, '_')
const seamArgv = ($: Dollar, sub: string, args: readonly string[]) => ['bash', `${$.plugin.root}/hooks/remote-reply/seam.sh`, sub, ...args]

// 스풀 루트가 디렉터리로 있는가. 없으면 모드는 잠든 채로 아무것도 하지 않는다.
async function isAwake($: Dollar): Promise<boolean> {
  try {
    await $.fs.list(spoolRoot())
    return true
  } catch {
    return false
  }
}

// 디렉터리에 있는 봉투 이름. 디렉터리가 없으면 빈 목록이다.
async function envelopes($: Dollar, dir: string): Promise<string[]> {
  try {
    return (await $.fs.list(dir)).filter(one => one.kind === 'file' && one.name.endsWith('.json') && !one.name.startsWith('.')).map(one => one.name).sort()
  } catch {
    return []
  }
}

// 정방향 색인의 런 id. 색인이 없으면 빈 목록이다.
async function indexRuns($: Dollar, sid: string): Promise<string[]> {
  try {
    const text = await $.fs.read(`${stateDir}/session/${sid}`)
    if (typeof text !== 'string') return []
    return text.split('\n').filter(line => /^[A-Za-z0-9-]{1,64}$/.test(line))
  } catch {
    return []
  }
}

async function seam($: Dollar, sub: string, args: readonly string[], stdin: string): Promise<string> {
  const r = await $.process.run(seamArgv($, sub, args), { stdin, timeoutMs: SEAM_TIMEOUT_MS })
  return r.exitCode === 0 ? r.stdout : ''
}

async function isIdle($: Dollar, now: number): Promise<boolean> {
  return !isTurnRunning && now - lastHumanAt >= IDLE_MS
}

// 시계 콜백은 일을 기다리지 않고 곧바로 돌아오며, 거부가 밖으로 나가지 않게 일 전체를 잡는다.
function armScan($: Dollar, now: number) {
  scanTimer?.cancel()
  lastScanAt = now
  scanTimer = $.clock.every(SCAN_MS, () => {
    onScan($).catch(() => undefined)
  })
}

function armWatch($: Dollar, now: number) {
  watchTimer?.cancel()
  lastWatchAt = now
  watchTimer = $.clock.every(WATCH_MS, () => {
    onWatch($).catch(() => undefined)
  })
}

async function onScan($: Dollar) {
  const now = await $.clock.now()
  lastScanAt = now
  if (now - lastWatchAt > WATCH_STALL_MS) armWatch($, now)
  await tick($)
}

async function onWatch($: Dollar) {
  const now = await $.clock.now()
  lastWatchAt = now
  if (now - lastScanAt > SCAN_STALL_MS) armScan($, now)
}

// 시계는 거부된 주기에서 끝난다. 모드가 듣는 모든 사건에서 같은 판정으로 둘을 다시 건다.
async function recover($: Dollar) {
  if (!isActive) return
  const now = await $.clock.now()
  if (now - lastScanAt > SCAN_STALL_MS) armScan($, now)
  if (now - lastWatchAt > WATCH_STALL_MS) armWatch($, now)
}

async function tick($: Dollar) {
  if (!isActive || isTicking) return
  isTicking = true
  try {
    await look($)
  } finally {
    isTicking = false
  }
}

const formArg = (t: FormTarget) => ({ form_id: t.form_id, session_id: t.session_id, questions: t.questions })

// 살핌 틱 하나: 이름만 보고, 후보가 없으면 프로세스를 띄우지 않는다.
async function look($: Dollar) {
  if (!(await isAwake($))) return
  ticks += 1
  const sid = await $.session.id()
  if (ticks % CLEANUP_TICKS === 0) await seam($, 'cleanup', [], JSON.stringify({ session_id: sid }))
  const own = await envelopes($, `${spoolRoot()}/inbox/s-${safeSid(sid)}`)
  const runNames: string[] = []
  for (const run of await indexRuns($, sid)) {
    for (const name of await envelopes($, `${spoolRoot()}/inbox/r-${run}`)) runNames.push(`${run}/${name}`)
  }
  const target = own.length > 0 ? await openFormTarget($) : null
  if (target === null && runNames.length === 0) return
  const now = await $.clock.now()
  const idle = await isIdle($, now)
  const key = JSON.stringify([own, runNames, target?.form_id ?? null, idle])
  if (key === lastScanKey && now - lastScanCallAt < RESCAN_MS) return
  lastScanKey = key
  lastScanCallAt = now
  const raw = await seam($, 'scan', [], JSON.stringify({ session_id: sid, form: target ? formArg(target) : null }))
  let out: ScanOut
  try {
    out = JSON.parse(raw) as ScanOut
  } catch {
    return
  }
  if (out.form && target && (await applyForm($, sid, target, out.form))) return
  const first = out.wake?.[0]
  if (first && (await isIdle($, await $.clock.now()))) await wake($, sid, first)
}

// 질문지 봉투 하나: 초안이 없을 때만 수령하고, 원자 갱신이 소비했고 엔진이 제출을 받았을
// 때만 기록한다. 소비하지 못했거나 제출이 드롭됐으면 방금 만든 수령 표지를 거둔다 — 드롭된
// 묶음은 대화에 들어가지 않았으므로 적용 기록을 쓰면 제출되지 않은 답이 적용됨으로 나간다.
async function applyForm($: Dollar, sid: string, target: FormTarget, form: NonNullable<ScanOut['form']>): Promise<boolean> {
  if (target.hasDraft) return false
  const stdin = JSON.stringify({ session_id: sid, form: formArg(target) })
  const picked = (await seam($, 'form-pick', [form.reply_id], stdin)).trim()
  if (picked !== form.reply_id) return false
  const delivered = await applyRemote($, target.form_id, form.picks)
  if (delivered.consumed && delivered.dropped === undefined) {
    await seam($, 'form-record', [sid, form.reply_id], delivered.text)
    return true
  }
  await seam($, 'form-unpick', [form.reply_id], JSON.stringify({ session_id: sid }))
  return delivered.consumed
}

async function wake($: Dollar, sid: string, one: Wake) {
  const line = (await seam($, 'wake-mark', [one.run_id, one.reply_id], JSON.stringify({ session_id: sid }))).replace(/\n$/, '')
  if (!WAKE_RE.test(line)) return
  await $.prompt.submit({ text: line })
}

// S-open 의 대기 자식에서 첫 줄을 읽는다. 자식이 줄 없이 끝나거나 뜨지 못하면 undefined.
async function firstLine(child: AsyncGenerator<{ stream: string; text: string }, unknown>): Promise<string | undefined> {
  let buffered = ''
  for (;;) {
    const piece = await child.next()
    if (piece.done) return undefined
    if (piece.value.stream !== 'stdout') continue
    buffered += piece.value.text
    const at = buffered.indexOf('\n')
    if (at >= 0) return buffered.slice(0, at)
  }
}

// 열린 질문 하나를 두고 로컬 대화창과 원격 봉투가 경합한다. 승자는 이 훅이 돌려준 값이다 —
// 확정을 시작하기 전에 로컬이 끝났으면 로컬 결과를 그대로 돌려주고 기록은 남지 않는다.
async function race($: Dollar, e: { tool_use_id: string; questions: Question[] }, local: Promise<unknown>): Promise<unknown> {
  let isLocalDone = false
  const localDone = local.then(
    () => {
      isLocalDone = true
      return { kind: 'local' as const }
    },
    () => {
      isLocalDone = true
      return { kind: 'local' as const }
    },
  )
  const sid = await $.session.id()
  const call = { session_id: sid, tool_use_id: e.tool_use_id, questions: e.questions }
  const rejected: string[] = []
  for (;;) {
    if (isLocalDone) return local
    const child = $.process.spawn({ argv: seamArgv($, 'wait', []), input: JSON.stringify({ ...call, rejected }) })
    const found = firstLine(child).then(
      line => ({ kind: 'found' as const, line }),
      () => ({ kind: 'found' as const, line: undefined }),
    )
    const first = await Promise.race([localDone, found])
    if (first.kind === 'local') {
      void child.return(undefined).catch(() => undefined)
      return local
    }
    const [addr, rid] = (first.line ?? '').split(' ')
    if (!addr || !rid) return local
    if (isLocalDone) return local
    let answers: unknown
    try {
      answers = JSON.parse(await seam($, 'commit', [addr, rid], JSON.stringify(call)))
    } catch {
      answers = undefined
    }
    if (answers && typeof answers === 'object' && !Array.isArray(answers)) return { result: { questions: e.questions, answers } }
    rejected.push(rid)
  }
}

export const register: Register = on => {
  // 대화형이고 표지 다섯이 모두 비어 있고 HOME 이 있을 때만 활성이 된다. /clear·재개로
  // 다시 오면 같은 판정을 다시 한다. 판정이나 시계가 실패해도 세션은 그대로 간다.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    try {
      scanTimer?.cancel()
      watchTimer?.cancel()
      scanTimer = undefined
      watchTimer = undefined
      isActive = false
      if (!(await pipelineMarked($))) {
        home = (await $.env.get('HOME')) ?? ''
        if (home !== '') {
          stateDir = ((await $.env.get('XDG_STATE_HOME')) || `${home}/.local/state`) + '/cc-cmds'
          const now = await $.clock.now()
          isActive = true
          isTurnRunning = false
          lastHumanAt = now
          lastScanKey = ''
          lastScanCallAt = 0
          ticks = 0
          armScan($, now)
          armWatch($, now)
          if (await isAwake($)) await seam($, 'cleanup', [], JSON.stringify({ session_id: await $.session.id() }))
        }
      }
    } catch {
      // 위 주석과 같다.
    }

    return next(e)
  })

  // 매처는 validate 가 소스에서 읽으므로 상수가 아니라 리터럴로 적는다. .catch 를 두지 않는다 —
  // 로컬 대화창이 거절로 끝나면 그 거절이 그대로 나가야 하고, 다시 next(e) 를 부르면 대화창이
  // 한 번 더 열린다. 그래서 next(e) 앞의 일은 거부를 스스로 삼킨다.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    await recover($).catch(() => undefined)
    const args = e as unknown as { tool_use_id: string; questions?: Question[]; answers?: unknown }
    if (args.answers !== undefined || !Array.isArray(args.questions)) return next(e)
    if (!(await isAwake($))) return next(e)
    const local = next(e)
    // 경합이 실패하면 로컬 결과만 기다린다.
    try {
      return (await race($, { tool_use_id: args.tool_use_id, questions: args.questions }, local)) as Awaited<typeof local>
    } catch {
      return local
    }
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    isTurnRunning = true
    await recover($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    isTurnRunning = false
    await recover($)

    return next(e)
  }).catch(($, e, next) => next(e))

  // 사람 입력: 입력 칸 편집, 기록 불러오기·되돌리기, 사람이나 원격 제어의 제출.
  on('prompt.edit', async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.change', { origin: { kind: 'history' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.change', { origin: { kind: 'undo' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  // 플러그인 출처 제출(깨우기 자신, 질문지 묶음)은 사람 입력이 아니므로 듣지 않는다.
  on('prompt.submit', { origin: { kind: 'composer' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.submit', { origin: { kind: 'bridge' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))
}

async function noteHuman($: Dollar) {
  if (!isActive) return
  lastHumanAt = await $.clock.now()
  await recover($)
}
