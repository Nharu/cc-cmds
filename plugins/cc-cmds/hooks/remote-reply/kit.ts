// 원격 답 모드 시험의 공용 세계. 같은 진입으로 실리는 런 패널과 질문지까지 돌 수 있게
// 엔진 밑의 연산(세션·패널·상태 줄·보관·시계·환경)을 스텁으로 세우고, 스풀은 메모리 안의
// 디렉터리 이름표로, seam.sh 는 하위 명령마다 정해 둔 출력으로 흉내 낸다. 표지 변수 다섯은
// 늘 명시적으로 모의해 호스트 환경을 읽지 않으며, 세계 연산의 스텁은 { value } 형식으로 답한다.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'

export const MARKS = ['CC_PIPELINE_SEGMENT', 'CC_PIPELINE_STAGE_ID', 'CC_PIPELINE_SHIFT_ID', 'CC_PIPELINE_RUN_ID', 'CC_PIPELINE_REENTRY'] as const
export const HOME = '/h'
export const ROOT = '/h/.local/state/cc-cmds/attention'
export const STATE = '/x/cc-cmds'
export const SID = 'sid-1'
export const OWN = `${ROOT}/inbox/s-${SID}`

export type SeamCall = { sub: string; args: string[]; stdin?: string }
export type Reply = string | string[] | ((c: SeamCall) => string)
export type Submitted = { text: string; origin: { kind: string; name?: string } }

export type WorldOptions = {
  env?: Partial<Record<(typeof MARKS)[number], string>>
  // null 이면 HOME 을 두지 않는다.
  home?: string | null
  // 거짓이면 스풀 루트가 없다.
  spool?: boolean
  store?: Record<string, unknown>
}

const enoent = () => Object.assign(new Error('ENOENT: no such file or directory'), { code: 'ENOENT' })

export function world(on: On, options: WorldOptions = {}) {
  const w = {
    sessionId: SID,
    // 스풀 디렉터리 경로 → 파일 이름. 없는 경로는 디렉터리가 아니다.
    dirs: {} as Record<string, string[]>,
    files: {} as Record<string, string>,
    seams: [] as SeamCall[],
    replies: {} as Record<string, Reply>,
    // 하위 명령이 답하기 전에 세계에서 일어날 일(그 사이 사람이 질문지를 바꾸는 따위).
    before: {} as Record<string, ($: any) => Promise<void>>,
    spawns: [] as { argv: string[]; input?: string }[],
    // 대기 자식마다 낼 한 줄. undefined 면 줄 없이 끝난다.
    waits: [] as (string | undefined)[],
    waitDelayMs: 1000,
    isSpawnFailing: false,
    // 로컬 대화창: 이만큼 뒤에 이 답으로 끝난다.
    localDelayMs: 5000,
    localAnswers: { '어디까지?': '좁게' } as Record<string, string>,
    locals: 0,
    lists: 0,
    submits: [] as Submitted[],
    // 있으면 엔진이 제출을 받지 않고 이 사유로 드롭한다(서 있는 Stop, 호스트 한도).
    submitDrop: undefined as string | undefined,
    toasts: [] as string[],
    refusedEvery: new Set<number>(),
  }
  mock.env(on, {
    ...(options.home === null ? {} : { HOME: options.home ?? HOME }),
    XDG_STATE_HOME: '/x',
    CC_PIPELINE_SEGMENT: '',
    CC_PIPELINE_STAGE_ID: '',
    CC_PIPELINE_SHIFT_ID: '',
    CC_PIPELINE_RUN_ID: '',
    CC_PIPELINE_REENTRY: '',
    ...options.env,
  })
  if (options.spool !== false) w.dirs[ROOT] = []
  // mock.clock 도 clock.every 를 받으므로, 이 훅들은 모드의 두 주기에만 매처로 걸고 먼저 둔다.
  on('clock.every', { ms: 15_000 }, (_$, e, next) => (w.refusedEvery.has(e.ms) ? { deny: '주기 거부' } : next(e)))
  on('clock.every', { ms: 40_000 }, (_$, e, next) => (w.refusedEvery.has(e.ms) ? { deny: '주기 거부' } : next(e)))
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on, options.store ?? {})
  // 이벤트는 결과를 그대로 돌려준다.
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_$, e) => {
    w.submits.push({ text: e.text, origin: e.origin as Submitted['origin'] })
    if (w.submitDrop !== undefined) return { drop: w.submitDrop }

    return { text: e.text, context: e.context }
  })
  on('prompt.change', (_$, e) => ({ text: e.text }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  // 로컬 대화창. 플러그인의 tool.call 훅 아래에서 사람이 답한다.
  on('tool.call', { tool: 'AskUserQuestion' }, async (_$, e: any) => {
    w.locals += 1
    await clock.sleep(w.localDelayMs)

    return { result: { questions: e.questions, answers: w.localAnswers } }
  })
  // 세계 연산.
  on('session.id', () => ({ value: w.sessionId }))
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('tool.register', (_$, e) => ({ value: { tool: `mcp__cc-cmds__${e.name}` } }))
  on('command.register', () => ({ value: undefined }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.focus', () => ({}))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)

    return { value: undefined }
  })
  on('fs.stat', () => {
    throw enoent()
  })
  on('fs.list', (_$, e) => {
    w.lists += 1
    const names = w.dirs[e.path]
    if (!names) throw enoent()

    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    const text = w.files[e.path]
    if (text === undefined) throw enoent()

    return { value: text }
  })
  // seam.sh 만 기록하고 정해 둔 출력으로 답한다. 다른 헬퍼(런 패널, 배너)는 빈 출력이다.
  on('process.run', async ($, e) => {
    const init = (e.init ?? {}) as { stdin?: string }
    const at = e.argv.findIndex(a => a.endsWith('/hooks/remote-reply/seam.sh'))
    let stdout = ''
    if (at >= 0) {
      const c: SeamCall = { sub: e.argv[at + 1] ?? '', args: e.argv.slice(at + 2), stdin: init.stdin }
      w.seams.push(c)
      await w.before[c.sub]?.($)
      const r = w.replies[c.sub]
      stdout = typeof r === 'function' ? r(c) : Array.isArray(r) ? (r.shift() ?? '') : (r ?? '')
    }

    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* (_$, e) {
    w.spawns.push({ argv: [...e.argv], input: e.input })
    if (w.isSpawnFailing) throw new Error('spawn 실패')
    const line = w.waits.shift()
    await clock.sleep(w.waitDelayMs)
    if (line !== undefined) yield { stream: 'stdout' as const, text: `${line}\n` }

    return { code: 0, signal: null }
  })

  return { w, clock }
}

export const start = ($: any, isInteractive = true) =>
  $.session.start({ cwd: '/work', surface: isInteractive ? 'terminal' : null, isInteractive })

export const ask = ($: any, toolUseId: string, extra: Record<string, unknown> = {}) =>
  $.tool.call({ tool: 'AskUserQuestion', tool_use_id: toolUseId, questions: QUESTIONS, ...extra })

export const QUESTIONS = [
  { question: '어디까지?', header: '범위', multiSelect: false, options: [{ label: '좁게', description: '좁게' }, { label: '넓게', description: '넓게' }] },
]

export const prompt = ($: any, text: string, origin: Record<string, unknown> = { kind: 'composer' }) =>
  $.prompt.submit({ text, origin, wait: false })

export const turnStart = ($: any, agentId?: string) => $.turn.start({ text: '', turnId: 't', ...(agentId ? { agentId } : {}) })

export const turnDone = ($: any, agentId?: string) =>
  $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer', ...(agentId ? { agentId } : {}) })

export const seamSubs = (w: { seams: SeamCall[] }) => w.seams.map(c => c.sub)
